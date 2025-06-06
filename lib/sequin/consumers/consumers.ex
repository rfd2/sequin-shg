defmodule Sequin.Consumers do
  @moduledoc false
  import Ecto.Query

  alias Sequin.Accounts
  alias Sequin.Consumers.AcknowledgedMessages
  alias Sequin.Consumers.Backfill
  alias Sequin.Consumers.ConsumerEvent
  alias Sequin.Consumers.ConsumerEventData
  alias Sequin.Consumers.ConsumerEventData.Metadata
  alias Sequin.Consumers.ConsumerRecord
  alias Sequin.Consumers.FunctionTransform
  alias Sequin.Consumers.HttpEndpoint
  alias Sequin.Consumers.SequenceFilter
  alias Sequin.Consumers.SequenceFilter.CiStringValue
  alias Sequin.Consumers.SequenceFilter.ColumnFilter
  alias Sequin.Consumers.SequenceFilter.DateTimeValue
  alias Sequin.Consumers.SequenceFilter.NullValue
  alias Sequin.Consumers.SinkConsumer
  alias Sequin.Consumers.SourceTable
  alias Sequin.Consumers.Transform
  alias Sequin.Databases.PostgresDatabase
  alias Sequin.Databases.PostgresDatabaseTable
  alias Sequin.Databases.Sequence
  alias Sequin.Error
  alias Sequin.Health
  alias Sequin.Health.Event
  alias Sequin.Metrics
  alias Sequin.Repo
  alias Sequin.Runtime.ConsumerLifecycleEventWorker
  alias Sequin.Time
  alias Sequin.Tracer.Server, as: TracerServer
  alias Sequin.Transforms.Message
  alias Sequin.Transforms.MiniElixir.Validator

  require Logger

  @stream_schema Application.compile_env!(:sequin, [Sequin.Repo, :stream_schema_prefix])
  @config_schema Application.compile_env!(:sequin, [Sequin.Repo, :config_schema_prefix])

  @type consumer :: SinkConsumer.t()

  def posthog_ets_table, do: :consumer_ack_events

  def stream_schema, do: @stream_schema
  def config_schema, do: @config_schema

  # Consumers

  def kind(%SinkConsumer{type: type}), do: type

  def source_table(%{source_tables: [], sequence: %Sequence{} = sequence} = consumer) do
    %PostgresDatabase{} = postgres_database = consumer.postgres_database
    %SequenceFilter{} = filter = consumer.sequence_filter
    table = Sequin.Enum.find!(postgres_database.tables, &(&1.oid == sequence.table_oid))
    primary_key_attnums = table.columns |> Enum.filter(& &1.is_pk?) |> Enum.map(& &1.attnum)

    %SourceTable{
      actions: filter.actions,
      group_column_attnums: filter.group_column_attnums || primary_key_attnums,
      sort_column_attnum: sequence.sort_column_attnum,
      oid: sequence.table_oid,
      schema_name: sequence.table_schema,
      table_name: sequence.table_name,
      column_filters:
        Enum.map(consumer.sequence_filter.column_filters, fn filter_column ->
          %SequenceFilter.ColumnFilter{
            column_attnum: filter_column.column_attnum,
            operator: filter_column.operator,
            value: filter_column.value,
            is_jsonb: filter_column.is_jsonb,
            jsonb_path: filter_column.jsonb_path
          }
        end)
    }
  end

  def source_table(%{source_tables: [source_table]}) do
    source_table
  end

  def source_table(_), do: nil

  def get_consumer(consumer_id) do
    get_sink_consumer(consumer_id)
  end

  def get_consumer!(consumer_id) do
    case get_consumer(consumer_id) do
      {:ok, consumer} -> consumer
      {:error, _} -> raise Error.not_found(entity: :consumer)
    end
  end

  def get_consumer_for_account(account_id, consumer_id) do
    account_id
    |> SinkConsumer.where_account_id()
    |> SinkConsumer.where_id_or_name(consumer_id)
    |> preload(:sequence)
    |> Repo.one()
  end

  def reload(%ConsumerEvent{} = ce) do
    ce.consumer_id
    |> ConsumerEvent.where_consumer_id()
    |> ConsumerEvent.where_commit_lsn(ce.commit_lsn)
    |> Repo.one()
  end

  def reload(%ConsumerRecord{} = cr) do
    cr.consumer_id
    |> ConsumerRecord.where_consumer_id()
    |> ConsumerRecord.where_id(cr.id)
    |> Repo.one()
  end

  def all_consumers do
    Repo.all(SinkConsumer)
  end

  def list_consumers_for_account(account_id, preload \\ []) do
    account_id
    |> SinkConsumer.where_account_id()
    |> preload(^preload)
    |> Repo.all()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  def list_sink_consumers_for_account(account_id, preload \\ []) do
    account_id
    |> SinkConsumer.where_account_id()
    |> preload(^preload)
    |> Repo.all()
  end

  def count_sink_consumers_for_account(account_id) do
    account_id
    |> SinkConsumer.where_account_id()
    |> Repo.aggregate(:count, :id)
  end

  def count_non_disabled_sink_consumers do
    :disabled
    |> SinkConsumer.where_status_not()
    |> Repo.aggregate(:count, :id)
  end

  def list_transforms_for_account(account_id) do
    account_id
    |> Transform.where_account_id()
    |> Repo.all()
  end

  def get_transform(id) do
    case Repo.get(Transform, id) do
      nil -> {:error, Error.not_found(entity: :transform, params: %{id: id})}
      transform -> {:ok, transform}
    end
  end

  def get_transform_for_account(account_id, id) do
    account_id
    |> Transform.where_account_id()
    |> Transform.where_id(id)
    |> Repo.one()
    |> case do
      nil -> {:error, Error.not_found(entity: :transform, params: %{id: id, account_id: account_id})}
      transform -> {:ok, transform}
    end
  end

  def get_transform_for_account!(account_id, id) do
    case get_transform_for_account(account_id, id) do
      {:ok, transform} -> transform
      {:error, error} -> raise error
    end
  end

  def find_transform(account_id, params) do
    params
    |> Enum.reduce(Transform.where_account_id(account_id), fn
      {:name, name}, query -> Transform.where_name(query, name)
      {:id, id}, query -> Transform.where_id(query, id)
    end)
    |> Repo.one()
    |> case do
      nil -> {:error, Error.not_found(entity: :transform, params: params)}
      transform -> {:ok, transform}
    end
  end

  def create_transform(account_id, params) do
    Repo.transact(fn ->
      %Transform{account_id: account_id}
      |> Transform.create_changeset(params)
      |> Repo.insert()
      |> case do
        {:ok, transform} ->
          ConsumerLifecycleEventWorker.enqueue(:create, :transform, transform.id)
          {:ok, transform}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def update_transform(account_id, id, params) do
    Repo.transact(fn ->
      %Transform{id: id, account_id: account_id}
      |> Transform.update_changeset(params)
      |> Repo.update()
      |> case do
        {:ok, transform} ->
          ConsumerLifecycleEventWorker.enqueue(:update, :transform, transform.id)
          {:ok, transform}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def delete_transform(account_id, id) do
    with {:ok, transform} <- get_transform_for_account(account_id, id) do
      transform
      |> Transform.changeset(%{})
      |> Ecto.Changeset.foreign_key_constraint(:id, name: "sink_consumers_transform_id_fkey")
      |> Ecto.Changeset.foreign_key_constraint(:id, name: "sink_consumers_routing_id_fkey")
      |> Repo.delete()
    end
  end

  @doc """
  Calculates the maximum memory bytes allowed for a consumer.
  """
  @spec max_memory_bytes_for_consumer(SinkConsumer.t()) ::
          non_neg_integer()
  def max_memory_bytes_for_consumer(%SinkConsumer{} = consumer) do
    round(Sequin.Size.mb(consumer.max_memory_mb) * 0.8)
  end

  @doc """
  Calculates the maximum memory bytes allowed for a consumer when a system-wide max is in place.

  Takes into account both:
  - The consumer's configured max_memory_mb setting
  - The system-wide memory limit divided among all non-disabled consumers

  ## Returns
    The lower of:
    * Consumer's max_memory_mb converted to bytes * 0.8
    * (system_max_memory_bytes / number of non-disabled consumers) * 0.8
  """
  @spec max_system_memory_bytes_for_consumer(SinkConsumer.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def max_system_memory_bytes_for_consumer(%SinkConsumer{} = consumer, consumer_count, system_max_memory_bytes) do
    consumer_max_memory_bytes = max_memory_bytes_for_consumer(consumer)

    # Some tests may call this with 0 consumers actually persisted
    consumer_count = max(consumer_count, 1)

    system_per_consumer_max_memory_bytes = round(div(system_max_memory_bytes, consumer_count) * 0.8)

    min(
      consumer_max_memory_bytes,
      system_per_consumer_max_memory_bytes
    )
  end

  def earliest_sink_consumer_inserted_at_for_account(account_id) do
    account_id
    |> SinkConsumer.where_account_id()
    |> Repo.aggregate(:min, :inserted_at)
  end

  def list_consumers_for_replication_slot(replication_slot_id) do
    replication_slot_id
    |> SinkConsumer.where_replication_slot_id()
    |> Repo.all()
  end

  def list_consumers_for_sequence(sequence_id) do
    sequence_id
    |> SinkConsumer.where_sequence_id()
    |> Repo.all()
  end

  def list_consumers_for_transform(account_id, transform_id, preload \\ []) do
    account_id
    |> SinkConsumer.where_account_id()
    |> SinkConsumer.where_transform_or_function_id(transform_id)
    |> preload(^preload)
    |> Repo.all()
  end

  def list_sink_consumers_for_http_endpoint(http_endpoint_id) do
    http_endpoint_id
    |> SinkConsumer.where_http_endpoint_id()
    |> Repo.all()
  end

  def list_sink_consumers_with_active_backfill do
    Repo.all(SinkConsumer.where_active_backfill())
  end

  def table_reader_finished(consumer_id) do
    consumer = get_consumer!(consumer_id)

    case Repo.preload(consumer, :active_backfill) do
      %{active_backfill: %Backfill{} = backfill} ->
        update_backfill(backfill, %{state: :completed})

      _ ->
        :ok
    end
  end

  def create_sink_consumer(account_id, attrs, opts \\ [])

  def create_sink_consumer(account_id, attrs, skip_lifecycle: true) do
    res =
      %SinkConsumer{account_id: account_id}
      |> SinkConsumer.create_changeset(attrs)
      |> Repo.insert()

    with {:ok, consumer} <- res do
      # TODO: Confirm why this is called
      consumer = Repo.reload!(consumer)
      {:ok, consumer}
    end
  end

  def create_sink_consumer(account_id, attrs, _opts) do
    Repo.transact(fn ->
      res =
        %SinkConsumer{account_id: account_id}
        |> SinkConsumer.create_changeset(attrs)
        |> Repo.insert()

      with {:ok, consumer} <- res,
           consumer = Repo.reload!(consumer),
           :ok <- create_consumer_partition(consumer),
           {:ok, _} <- ConsumerLifecycleEventWorker.enqueue(:create, :sink_consumer, consumer.id) do
        {:ok, consumer}
      end
    end)
  end

  def update_sink_consumer(%SinkConsumer{} = consumer, attrs, opts \\ []) do
    Repo.transact(fn ->
      res =
        consumer
        |> SinkConsumer.update_changeset(attrs)
        |> Repo.update()

      with {:ok, consumer} <- res do
        unless opts[:skip_lifecycle] do
          ConsumerLifecycleEventWorker.enqueue(:update, :sink_consumer, consumer.id)
        end

        {:ok, consumer}
      end
    end)
  end

  def delete_sink_consumer(consumer) do
    Repo.transact(fn ->
      with {:ok, _} <- Repo.delete(consumer),
           :ok <- delete_consumer_partition(consumer) do
        ConsumerLifecycleEventWorker.enqueue(:delete, :sink_consumer, consumer.id, %{
          "replication_slot_id" => consumer.replication_slot_id
        })
      end
    end)
  end

  def partition_name(%{message_kind: :event} = consumer) do
    "consumer_events_#{consumer.seq}"
  end

  def partition_name(%{message_kind: :record} = consumer) do
    "consumer_records_#{consumer.seq}"
  end

  # SinkConsumer

  def get_sink_consumer(consumer_id) do
    case Repo.get(SinkConsumer, consumer_id) do
      nil -> {:error, Error.not_found(entity: :sink_consumer, params: %{id: consumer_id})}
      consumer -> {:ok, consumer}
    end
  end

  def get_sink_consumer!(consumer_id) do
    case get_sink_consumer(consumer_id) do
      {:ok, consumer} -> consumer
      {:error, error} -> raise error
    end
  end

  def get_sink_consumer_for_account(account_id, consumer_id) do
    account_id
    |> SinkConsumer.where_account_id()
    |> SinkConsumer.where_id(consumer_id)
    |> Repo.one()
    |> case do
      nil -> {:error, Error.not_found(entity: :consumer)}
      consumer -> {:ok, consumer}
    end
  end

  def find_sink_consumer(account_id, params \\ []) do
    params
    |> Enum.reduce(SinkConsumer.where_account_id(account_id), fn
      {:id, id}, query -> SinkConsumer.where_id(query, id)
      {:name, name}, query -> SinkConsumer.where_name(query, name)
      {:id_or_name, id_or_name}, query -> SinkConsumer.where_id_or_name(query, id_or_name)
      {:type, type}, query -> SinkConsumer.where_type(query, type)
      {:sequence_id, sequence_id}, query -> SinkConsumer.where_sequence_id(query, sequence_id)
      {:preload, preload}, query -> preload(query, ^preload)
    end)
    |> Repo.one()
    |> case do
      nil -> {:error, Error.not_found(entity: :consumer)}
      consumer -> {:ok, consumer}
    end
  end

  def list_active_sink_consumers(preloads \\ []) do
    :active
    |> SinkConsumer.where_status()
    |> preload(^preloads)
    |> Repo.all()
  end

  def list_active_sink_consumer_ids(preloads \\ []) do
    :active
    |> SinkConsumer.where_status()
    |> preload(^preloads)
    |> select([c], c.id)
    |> Repo.all()
  end

  @legacy_event_singleton_transform_cutoff_date ~D[2024-11-06]
  def consumer_features(%SinkConsumer{} = consumer) do
    consumer = Repo.lazy_preload(consumer, [:account])

    cond do
      Accounts.has_feature?(consumer.account, :legacy_event_transform) ->
        [legacy_event_transform: true]

      Date.before?(consumer.account.inserted_at, @legacy_event_singleton_transform_cutoff_date) ->
        [legacy_event_singleton_transform: true]

      true ->
        []
    end
  end

  # ConsumerEvent

  def get_consumer_event(consumer_id, ack_id: ack_id) do
    consumer_id
    |> ConsumerEvent.where_consumer_id()
    |> ConsumerEvent.where_ack_id(ack_id)
    |> Repo.one()
  end

  def get_consumer_event(consumer_id, commit_lsn) do
    consumer_event =
      consumer_id
      |> ConsumerEvent.where_consumer_id()
      |> ConsumerEvent.where_commit_lsn(commit_lsn)
      |> Repo.one()

    case consumer_event do
      nil -> {:error, Error.not_found(entity: :consumer_event)}
      consumer_event -> {:ok, consumer_event}
    end
  end

  def get_consumer_event!(consumer_id, commit_lsn) do
    case get_consumer_event(consumer_id, commit_lsn) do
      {:ok, consumer_event} -> consumer_event
      {:error, _} -> raise Error.not_found(entity: :consumer_event)
    end
  end

  def list_consumer_messages_for_consumer(%SinkConsumer{} = consumer, params \\ [], opts \\ []) do
    case consumer.message_kind do
      :event -> list_consumer_events_for_consumer(consumer.id, params, opts)
      :record -> list_consumer_records_for_consumer(consumer.id, params, opts)
    end
  end

  def list_consumer_events_for_consumer(consumer_id, params \\ [], opts \\ []) do
    base_query = ConsumerEvent.where_consumer_id(consumer_id)

    query =
      Enum.reduce(params, base_query, fn
        {:is_deliverable, false}, query ->
          ConsumerEvent.where_not_visible(query)

        {:is_deliverable, true}, query ->
          ConsumerEvent.where_deliverable(query)

        {:limit, limit}, query ->
          limit(query, ^limit)

        {:offset, offset}, query ->
          offset(query, ^offset)

        {:order_by, order_by}, query ->
          order_by(query, ^order_by)

        {:select, select}, query ->
          select(query, ^select)

        {:ids, ids}, query ->
          ConsumerEvent.where_ids(query, ids)

        {:wal_cursor_in, wal_cursors}, query ->
          ConsumerEvent.where_wal_cursor_in(query, wal_cursors)
      end)

    Repo.all(query, opts)
  end

  def upsert_consumer_messages(%SinkConsumer{} = consumer, messages) do
    case consumer.message_kind do
      :event -> upsert_consumer_events(messages)
      :record -> upsert_consumer_records(messages)
    end
  end

  defp upsert_consumer_events([]), do: {:ok, []}

  defp upsert_consumer_events(consumer_events) do
    now = DateTime.utc_now()

    events =
      Enum.map(consumer_events, fn %ConsumerEvent{} = event ->
        %ConsumerEvent{event | updated_at: now, inserted_at: now}
        |> Sequin.Map.from_ecto()
        |> drop_virtual_fields()
      end)

    # insert_all expects a plain outer-map, but struct embeds
    {count, _events} =
      Repo.insert_all(
        ConsumerEvent,
        events,
        on_conflict: {:replace, [:state, :updated_at, :deliver_count, :last_delivered_at, :not_visible_until]},
        conflict_target: [:consumer_id, :ack_id]
      )

    {:ok, count}
  end

  @exponential_backoff_max :timer.minutes(10)
  def advance_delivery_state_for_failure(message) do
    deliver_count = message.deliver_count + 1
    backoff_time = Time.exponential_backoff(:timer.seconds(1), deliver_count, @exponential_backoff_max)
    not_visible_until = DateTime.add(DateTime.utc_now(), backoff_time, :millisecond)

    %{message | deliver_count: deliver_count, not_visible_until: not_visible_until}
  end

  # ConsumerRecord

  def get_consumer_record(consumer_id, id) when is_integer(id) do
    consumer_record =
      consumer_id
      |> ConsumerRecord.where_consumer_id()
      |> ConsumerRecord.where_id(id)
      |> Repo.one()

    case consumer_record do
      nil -> {:error, Error.not_found(entity: :consumer_record)}
      consumer_record -> {:ok, consumer_record}
    end
  end

  def get_consumer_record(consumer_id, params) when is_list(params) or is_map(params) do
    consumer_id
    |> consumer_record_query(params)
    |> Repo.one()
    |> case do
      %ConsumerRecord{} = consumer_record -> {:ok, consumer_record}
      nil -> {:error, Error.not_found(entity: :consumer_record)}
    end
  end

  def get_consumer_record!(consumer_id, id) when is_integer(id) do
    case get_consumer_record(consumer_id, id) do
      {:ok, consumer_record} -> consumer_record
      {:error, error} -> raise error
    end
  end

  def list_consumer_records_for_consumer(consumer_id, params \\ [], opts \\ []) do
    consumer_id
    |> consumer_record_query(params)
    |> Repo.all(opts)
  end

  defp consumer_record_query(consumer_id, params) do
    base_query = ConsumerRecord.where_consumer_id(consumer_id)

    Enum.reduce(params, base_query, fn
      {:is_deliverable, false}, query ->
        ConsumerRecord.where_not_visible(query)

      {:is_deliverable, true}, query ->
        ConsumerRecord.where_deliverable(query)

      {:is_delivered, true}, query ->
        ConsumerRecord.where_not_visible(query)

      {:limit, limit}, query ->
        limit(query, ^limit)

      {:offset, offset}, query ->
        offset(query, ^offset)

      {:order_by, order_by}, query ->
        order_by(query, ^order_by)

      {:select, select}, query ->
        select(query, ^select)

      {:ids, ids}, query ->
        ConsumerRecord.where_ids(query, ids)

      {:wal_cursor_in, wal_cursors}, query ->
        ConsumerRecord.where_wal_cursor_in(query, wal_cursors)
    end)
  end

  @fast_count_threshold 50_000
  def fast_count_threshold, do: @fast_count_threshold

  def fast_count_messages_for_consumer(consumer, params \\ []) do
    query = consumer_messages_query(consumer, params)

    # This number can be pretty inaccurate
    result = Ecto.Adapters.SQL.explain(Repo, :all, query)
    [_, rows] = Regex.run(~r/rows=(\d+)/, result)

    case String.to_integer(rows) do
      count when count > @fast_count_threshold ->
        count

      _ ->
        count_messages_for_consumer(consumer, params)
    end
  end

  defp consumer_messages_query(%{message_kind: :record} = consumer, params) do
    Enum.reduce(params, ConsumerRecord.where_consumer_id(consumer.id), fn
      {:delivery_count_gte, delivery_count}, query ->
        ConsumerRecord.where_delivery_count_gte(query, delivery_count)

      {:is_delivered, true}, query ->
        ConsumerRecord.where_not_visible(query)

      {:is_deliverable, true}, query ->
        ConsumerRecord.where_deliverable(query)

      {:limit, limit}, query ->
        limit(query, ^limit)
    end)
  end

  defp consumer_messages_query(%{message_kind: :event} = consumer, params) do
    Enum.reduce(params, ConsumerEvent.where_consumer_id(consumer.id), fn
      {:delivery_count_gte, delivery_count}, query ->
        ConsumerEvent.where_delivery_count_gte(query, delivery_count)
    end)
  end

  def count_messages_for_consumer(consumer, params \\ []) do
    consumer
    |> consumer_messages_query(params)
    |> Repo.aggregate(:count, :id)
  end

  defp upsert_consumer_records([]), do: {:ok, []}

  defp upsert_consumer_records(consumer_records) do
    now = DateTime.utc_now()

    records =
      consumer_records
      |> Stream.map(fn %ConsumerRecord{} = record ->
        %ConsumerRecord{record | updated_at: now, inserted_at: now}
      end)
      # insert_all expects a plain outer-map, but struct embeds
      |> Stream.map(&Sequin.Map.from_ecto/1)
      |> Enum.map(&drop_virtual_fields/1)

    {count, _records} =
      Repo.insert_all(
        ConsumerRecord,
        records,
        on_conflict: {:replace, [:state, :updated_at, :deliver_count, :last_delivered_at, :not_visible_until]},
        conflict_target: [:consumer_id, :ack_id]
      )

    {:ok, count}
  end

  # Consumer Lifecycle

  # Convert the string to 16-bit int
  # Completely arbitrary number, but must be consistent
  @partition_lock_key "partition_lock_key" |> :erlang.crc32() |> rem(32_768)

  def create_consumer_partition(%{message_kind: kind} = consumer) when kind in [:event, :record] do
    table_name = if kind == :event, do: "consumer_events", else: "consumer_records"

    with {:ok, _} <- Repo.query("SELECT pg_advisory_xact_lock($1)", [@partition_lock_key]),
         {:ok, %Postgrex.Result{command: :create_table}} <-
           Repo.query("""
           CREATE TABLE #{stream_schema()}.#{partition_name(consumer)}
           PARTITION OF #{stream_schema()}.#{table_name}
           FOR VALUES IN ('#{consumer.id}');
           """) do
      :ok
    end
  end

  def delete_consumer_partition(%{message_kind: kind} = consumer) when kind in [:event, :record] do
    with {:ok, _} <- Repo.query("SELECT pg_advisory_xact_lock($1)", [@partition_lock_key]),
         {:ok, %Postgrex.Result{command: :drop_table}} <-
           Repo.query("""
           drop table if exists #{stream_schema()}.#{partition_name(consumer)};
           """) do
      :ok
    end
  end

  # Acking Messages
  @spec ack_messages(consumer(), [String.t()]) :: {:ok, non_neg_integer()}
  def ack_messages(_consumer, []) do
    {:ok, 0}
  end

  def ack_messages(%SinkConsumer{} = consumer, ack_ids) do
    msg_module =
      case consumer.message_kind do
        :event -> ConsumerEvent
        :record -> ConsumerRecord
      end

    {count, _} =
      consumer.id
      |> msg_module.where_consumer_id()
      |> msg_module.where_ack_ids(ack_ids)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  For Sequin Stream SinkConsumer only.

  Nack messages with backoff allows us to both nack a message and set its not_visible_until to some time in the future.
  This is easy to do in Postgres with a single entry. When we want to perform an update
  for multiple messages, cleanest thing to do is to craft an upsert query.
  """
  def nack_messages_with_backoff(%{message_kind: :event} = consumer, ack_ids_with_not_visible_until) do
    nack_messages_with_backoff(ConsumerEvent, consumer, ack_ids_with_not_visible_until)
  end

  def nack_messages_with_backoff(%{message_kind: :record} = consumer, ack_ids_with_not_visible_until) do
    nack_messages_with_backoff(ConsumerRecord, consumer, ack_ids_with_not_visible_until)
  end

  def nack_messages_with_backoff(model, consumer, ack_ids_with_not_visible_until) do
    Repo.transaction(fn ->
      # Get the list of ack_ids
      ack_ids = Map.keys(ack_ids_with_not_visible_until)

      # Select existing records and lock them
      # This will let us do an upsert on conflict to update each row individually
      # We don't want to insert a message that was already acked, hence the select
      # before the upsert
      existing_records =
        consumer.id
        |> model.where_consumer_id()
        |> model.where_ack_ids(ack_ids)
        |> lock("FOR UPDATE")
        |> Repo.all()

      # Prepare updates only for existing records
      updates =
        Enum.map(existing_records, fn existing_record ->
          not_visible_until = Map.fetch!(ack_ids_with_not_visible_until, existing_record.ack_id)

          existing_record
          |> Sequin.Map.from_ecto()
          |> Map.put(:not_visible_until, not_visible_until)
        end)

      # Perform the upsert
      Repo.insert_all(model, updates,
        on_conflict: [set: [not_visible_until: dynamic([cr], fragment("EXCLUDED.not_visible_until")), state: :available]],
        conflict_target: [:consumer_id, :ack_id]
      )
    end)
  end

  @doc """
  Resets visibility timeout for all messages, making them immediately available for redelivery.
  """
  def reset_all_message_visibilities(%SinkConsumer{message_kind: :record} = consumer) do
    now = DateTime.utc_now()

    {count, _} =
      consumer.id
      |> ConsumerRecord.where_consumer_id()
      # TODO: Do we need the state filter/check?
      |> ConsumerRecord.where_state_not(:acked)
      |> Repo.update_all(set: [not_visible_until: now, state: :available, updated_at: now])

    if count > 0 do
      publish_messages_changed(consumer.id)
    end

    :ok
  end

  def reset_all_message_visibilities(%SinkConsumer{message_kind: :event} = consumer) do
    now = DateTime.utc_now()

    {count, _} =
      consumer.id
      |> ConsumerEvent.where_consumer_id()
      |> Repo.update_all(set: [not_visible_until: now, state: :available, updated_at: now])

    if count > 0 do
      publish_messages_changed(consumer.id)
    end

    :ok
  end

  @doc """
  Resets visibility timeout for a specific message, making it immediately available for redelivery.
  """
  def reset_message_visibility(%SinkConsumer{message_kind: :record} = consumer, ack_id) do
    now = DateTime.utc_now()

    {count, _} =
      consumer.id
      |> ConsumerRecord.where_consumer_id()
      |> ConsumerRecord.where_ack_ids([ack_id])
      |> ConsumerRecord.where_state_not(:acked)
      |> Repo.update_all(set: [not_visible_until: now, state: :available, updated_at: now])

    if count > 0 do
      publish_messages_changed(consumer.id)
    end

    :ok
  end

  def reset_message_visibility(%SinkConsumer{message_kind: :event} = consumer, ack_id) do
    now = DateTime.utc_now()

    {count, _} =
      consumer.id
      |> ConsumerEvent.where_consumer_id()
      |> ConsumerEvent.where_ack_ids([ack_id])
      |> Repo.update_all(set: [not_visible_until: now, state: :available, updated_at: now])

    if count > 0 do
      publish_messages_changed(consumer.id)
    end

    :ok
  end

  defp publish_messages_changed(consumer_id) do
    :syn.publish(:consumers, {:messages_changed, consumer_id}, :messages_changed)
  end

  @spec after_messages_acked(SinkConsumer.t(), list(ConsumerRecord.t() | ConsumerEvent.t())) ::
          {:ok, non_neg_integer()}
  def after_messages_acked(%SinkConsumer{} = consumer, acked_messages) do
    count = length(acked_messages)
    Health.put_event(consumer, %Event{slug: :messages_delivered, status: :success})

    AcknowledgedMessages.store_messages(consumer.id, acked_messages)

    bytes_processed =
      Enum.sum_by(
        acked_messages,
        fn message when is_struct(message, ConsumerRecord) or is_struct(message, ConsumerEvent) ->
          message.encoded_data_size_bytes || message.payload_size_bytes
        end
      )

    Metrics.incr_consumer_messages_processed_count(consumer, count)
    Metrics.incr_consumer_messages_processed_throughput(consumer, count)
    Metrics.incr_consumer_messages_processed_bytes(consumer, bytes_processed)

    :telemetry.execute(
      [:sequin, :posthog, :event],
      %{event: "consumer_ack"},
      %{
        distinct_id: "00000000-0000-0000-0000-000000000000",
        properties: %{
          consumer_id: consumer.id,
          consumer_name: consumer.name,
          message_count: count,
          bytes_processed: bytes_processed,
          message_kind: consumer.message_kind,
          "$groups": %{account: consumer.account_id}
        }
      }
    )

    ack_ids = Enum.map(acked_messages, & &1.ack_id)
    TracerServer.messages_acked(consumer, ack_ids)

    {:ok, count}
  end

  # HttpEndpoint

  def get_http_endpoint(id) do
    case Repo.get(HttpEndpoint, id) do
      nil -> {:error, Error.not_found(entity: :http_endpoint)}
      http_endpoint -> {:ok, http_endpoint}
    end
  end

  def get_http_endpoint!(id) do
    case get_http_endpoint(id) do
      {:ok, http_endpoint} -> http_endpoint
      {:error, _} -> raise Error.not_found(entity: :http_endpoint)
    end
  end

  def list_http_endpoints(preload \\ []) do
    HttpEndpoint
    |> preload(^preload)
    |> Repo.all()
  end

  def list_http_endpoints_for_account(account_id, preload \\ []) do
    account_id
    |> HttpEndpoint.where_account_id()
    |> preload(^preload)
    |> Repo.all()
  end

  def list_local_tunnel_http_endpoints_for_account(account_id, preload \\ []) do
    account_id
    |> HttpEndpoint.where_account_id()
    |> HttpEndpoint.where_use_local_tunnel()
    |> preload(^preload)
    |> Repo.all()
  end

  def find_http_endpoint_for_account(account_id, params \\ []) do
    params
    |> Enum.reduce(HttpEndpoint.where_account_id(account_id), fn
      {:id, id}, query -> HttpEndpoint.where_id(query, id)
      {:name, name}, query -> HttpEndpoint.where_name(query, name)
      {:id_or_name, id_or_name}, query -> HttpEndpoint.where_id_or_name(query, id_or_name)
    end)
    |> Repo.one()
    |> case do
      %HttpEndpoint{} = http_endpoint -> {:ok, http_endpoint}
      nil -> {:error, Error.not_found(entity: :http_endpoint)}
    end
  end

  def create_http_endpoint(account_id, attrs, opts \\ []) do
    Repo.transact(fn ->
      res =
        %HttpEndpoint{account_id: account_id}
        |> HttpEndpoint.create_changeset(attrs)
        |> Repo.insert()

      with {:ok, http_endpoint} <- res do
        unless opts[:skip_lifecycle] do
          ConsumerLifecycleEventWorker.enqueue(:create, :http_endpoint, http_endpoint.id)
        end

        {:ok, http_endpoint}
      end
    end)
  end

  def update_http_endpoint(%HttpEndpoint{} = http_endpoint, attrs, opts \\ []) do
    Repo.transact(fn ->
      res =
        http_endpoint
        |> HttpEndpoint.update_changeset(attrs)
        |> Repo.update()

      with {:ok, http_endpoint} <- res do
        unless opts[:skip_lifecycle] do
          ConsumerLifecycleEventWorker.enqueue(:update, :http_endpoint, http_endpoint.id)
        end

        {:ok, http_endpoint}
      end
    end)
  end

  def delete_http_endpoint(%HttpEndpoint{} = http_endpoint, opts \\ []) do
    Repo.transact(fn ->
      res =
        http_endpoint
        |> Ecto.Changeset.change()
        |> Repo.delete()

      with {:ok, http_endpoint} <- res do
        unless opts[:skip_lifecycle] do
          ConsumerLifecycleEventWorker.enqueue(:delete, :http_endpoint, http_endpoint.id)
        end

        {:ok, http_endpoint}
      end
    end)
  rescue
    error in Postgrex.Error ->
      msg = Exception.message(error)

      if String.match?(msg, ~r/Cannot delete HTTP endpoint .* as it is in use by/) do
        "ERROR P0001 (raise_exception) " <> msg = msg
        {:error, Error.bad_request(message: msg)}
      else
        reraise error, __STACKTRACE__
      end
  end

  def test_reachability(%HttpEndpoint{} = http_endpoint) do
    case HttpEndpoint.uri(http_endpoint) do
      %URI{host: host} when is_binary(host) ->
        case :inet.gethostbyname(String.to_charlist(host)) do
          {:ok, _} -> {:ok, :reachable}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  def test_connect(%HttpEndpoint{} = http_endpoint) do
    case HttpEndpoint.uri(http_endpoint) do
      %URI{host: host, port: port} when is_binary(host) ->
        # Convert host to charlist as required by :gen_tcp.connect
        host_charlist = String.to_charlist(host)

        # Attempt to establish a TCP connection
        case :gen_tcp.connect(host_charlist, port, [], 5000) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            {:ok, :connected}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  # Source Table Matching
  def matches_message?(
        %{sequence: %Sequence{} = sequence, sequence_filter: %SequenceFilter{} = sequence_filter} = consumer,
        message
      ) do
    matches? = matches_message?(sequence, sequence_filter, message)

    Health.put_event(consumer, %Event{slug: :messages_filtered, status: :success})

    matches?
  rescue
    error in [ArgumentError] ->
      Health.put_event(consumer, %Event{
        slug: :messages_filtered,
        status: :fail,
        error:
          Error.service(
            code: :argument_error,
            message: Exception.message(error)
          )
      })

      reraise error, __STACKTRACE__
  end

  def matches_message?(consumer_or_wal_pipeline, message) do
    matches? =
      Enum.any?(consumer_or_wal_pipeline.source_tables, fn %SourceTable{} = source_table ->
        table_matches = source_table.oid == message.table_oid
        action_matches = action_matches?(source_table.actions, message.action)
        column_filters_match = column_filters_match_message?(source_table.column_filters, message)

        # Logger.debug("""
        # [Consumers]
        #   matches?: #{table_matches && action_matches && column_filters_match}
        #     table_matches: #{table_matches}
        #     action_matches: #{action_matches}
        #     column_filters_match: #{column_filters_match}

        #   consumer_or_wal_pipeline:
        #     #{inspect(consumer_or_wal_pipeline, pretty: true)}

        #   message:
        #     #{inspect(message, pretty: true)}
        # """)

        table_matches && action_matches && column_filters_match
      end)

    Health.put_event(consumer_or_wal_pipeline, %Event{slug: :messages_filtered, status: :success})

    matches?
  rescue
    error in [ArgumentError] ->
      Health.put_event(
        consumer_or_wal_pipeline,
        %Event{
          slug: :messages_filtered,
          status: :fail,
          error:
            Error.service(
              code: :argument_error,
              message: Exception.message(error)
            )
        }
      )

      reraise error, __STACKTRACE__
  end

  def matches_message?(%Sequence{} = sequence, %SequenceFilter{} = sequence_filter, message) do
    table_matches? = sequence.table_oid == message.table_oid
    actions_match? = action_matches?(sequence_filter.actions, message.action)
    column_filters_match? = column_filters_match_message?(sequence_filter.column_filters, message)

    table_matches? and actions_match? and column_filters_match?
  end

  def matches_record?(
        %{sequence: %Sequence{} = sequence, sequence_filter: %SequenceFilter{} = sequence_filter} = consumer,
        table_oid,
        record
      ) do
    table_matches? = sequence.table_oid == table_oid
    column_filters_match? = column_filters_match_record?(sequence_filter.column_filters, record)

    Health.put_event(consumer, %Event{slug: :messages_filtered, status: :success})

    table_matches? and column_filters_match?
  end

  def matches_record?(consumer, table_oid, record_attnums_to_values) do
    source_table = Sequin.Enum.find!(consumer.source_tables, &(&1.oid == table_oid))
    matches? = column_filters_match_record?(source_table.column_filters, record_attnums_to_values)

    Health.put_event(consumer, %Event{slug: :messages_filtered, status: :success})

    matches?
  end

  defp action_matches?(source_table_actions, message_action) do
    message_action in source_table_actions
  end

  defp column_filters_match_message?([], _message), do: true

  defp column_filters_match_message?(column_filters, message) do
    Enum.all?(column_filters, fn filter ->
      fields = if message.action == :delete, do: message.old_fields, else: message.fields
      field = Enum.find(fields, &(&1.column_attnum == filter.column_attnum))
      field && apply_filter(filter.operator, coerce_field_value(field.value, filter), filter.value)
    end)
  end

  defp column_filters_match_record?([], _message), do: true

  defp column_filters_match_record?(column_filters, record_attnums_to_values) do
    Enum.all?(column_filters, fn %ColumnFilter{} = filter ->
      field_value =
        record_attnums_to_values
        |> Map.get(filter.column_attnum)
        |> coerce_field_value(filter)

      apply_filter(filter.operator, field_value, filter.value)
    end)
  end

  defp coerce_field_value(value, %ColumnFilter{value: %CiStringValue{}}) when is_binary(value) do
    String.downcase(value)
  end

  defp coerce_field_value(value, %ColumnFilter{jsonb_path: jsonb_path}) when jsonb_path in [nil, ""], do: value

  defp coerce_field_value(value, %ColumnFilter{jsonb_path: jsonb_path}) when is_map(value) do
    path = String.split(jsonb_path, ".")
    get_in(value, path)
  rescue
    # Errors will happen when traversal hits an unsupported value type, like an array or a string.
    ArgumentError ->
      nil

    FunctionClauseError ->
      nil
  end

  defp coerce_field_value(value, _filter), do: value

  defp apply_filter(operator, %Date{} = field_value, %DateTimeValue{} = filter_value) do
    field_value_as_datetime = DateTime.new!(field_value, ~T[00:00:00])
    apply_filter(operator, field_value_as_datetime, filter_value)
  end

  defp apply_filter(operator, %NaiveDateTime{} = field_value, %DateTimeValue{} = filter_value) do
    field_value_as_datetime = DateTime.from_naive!(field_value, "Etc/UTC")
    apply_filter(operator, field_value_as_datetime, filter_value)
  end

  defp apply_filter(:==, field_value, %DateTimeValue{value: filter_value}) do
    DateTime.compare(field_value, filter_value) == :eq
  end

  defp apply_filter(:!=, field_value, %DateTimeValue{value: filter_value}) do
    DateTime.compare(field_value, filter_value) != :eq
  end

  defp apply_filter(:>, field_value, %DateTimeValue{value: filter_value}) do
    DateTime.after?(field_value, filter_value)
  end

  defp apply_filter(:<, field_value, %DateTimeValue{value: filter_value}) do
    DateTime.before?(field_value, filter_value)
  end

  defp apply_filter(:>=, field_value, %DateTimeValue{value: filter_value}) do
    DateTime.compare(field_value, filter_value) in [:gt, :eq]
  end

  defp apply_filter(:<=, field_value, %DateTimeValue{value: filter_value}) do
    DateTime.compare(field_value, filter_value) in [:lt, :eq]
  end

  defp apply_filter(:is_null, field_value, %NullValue{}) do
    is_nil(field_value)
  end

  defp apply_filter(:not_null, field_value, %NullValue{}) do
    not is_nil(field_value)
  end

  defp apply_filter(op, field_value, %{value: filter_value}) when op in [:==, :!=, :>, :<, :>=, :<=],
    do: apply(Kernel, op, [field_value, filter_value])

  defp apply_filter(:is_null, field_value, _), do: is_nil(field_value)
  defp apply_filter(:not_null, field_value, _), do: not is_nil(field_value)

  defp apply_filter(:in, field_value, %{value: filter_value}) when is_list(filter_value) do
    field_value in filter_value or to_string(field_value) in Enum.map(filter_value, &to_string/1)
  end

  defp apply_filter(:not_in, field_value, %{value: filter_value}) when is_list(filter_value) do
    field_value not in filter_value and
      to_string(field_value) not in Enum.map(filter_value, &to_string/1)
  end

  def enrich_source_tables(source_tables, %PostgresDatabase{} = postgres_database) do
    Enum.map(source_tables, fn source_table ->
      table = Sequin.Enum.find!(postgres_database.tables, &(&1.oid == source_table.oid))

      %Sequin.Consumers.SourceTable{
        source_table
        | schema_name: table.schema,
          table_name: table.name,
          column_filters: enrich_column_filters(source_table.column_filters, table.columns)
      }
    end)
  end

  defp enrich_column_filters(column_filters, columns) do
    Enum.map(column_filters, fn column_filter ->
      column = Sequin.Enum.find!(columns, &(&1.attnum == column_filter.column_attnum))
      %{column_filter | column_name: column.name}
    end)
  end

  @doc """
  Checks if there are any consumers that haven't been migrated to use Sequences.

  Returns `true` if there are any unmigrated consumers, `false` otherwise.
  """
  def any_unmigrated_consumers? do
    Enum.any?(all_consumers(), fn consumer -> is_nil(consumer.sequence_id) end)
  end

  def group_column_values(%SinkConsumer{} = consumer, record_data) do
    table = Sequin.Enum.find!(consumer.postgres_database.tables, &(&1.oid == consumer.sequence.table_oid))
    group_column_attnums = consumer.sequence_filter.group_column_attnums
    group_column_names = PostgresDatabaseTable.column_attnums_to_names(table, group_column_attnums)

    Enum.map(group_column_names, fn group_column_name ->
      Map.get(record_data.record, group_column_name)
    end)
  end

  def get_backfill(id) do
    case Repo.get(Backfill, id) do
      nil -> {:error, Error.not_found(entity: :backfill, params: %{id: id})}
      backfill -> {:ok, backfill}
    end
  end

  def get_backfill!(id) do
    case get_backfill(id) do
      {:ok, backfill} -> backfill
      {:error, error} -> raise error
    end
  end

  def get_backfill_for_sink_consumer(sink_consumer_id, backfill_id) do
    sink_consumer_id
    |> Backfill.where_sink_consumer_id()
    |> Backfill.where_id(backfill_id)
    |> Repo.one()
    |> case do
      nil -> {:error, Error.not_found(entity: :backfill, params: %{id: backfill_id})}
      backfill -> {:ok, backfill}
    end
  end

  def list_backfills_for_sink_consumer(sink_consumer_id) do
    sink_consumer_id
    |> Backfill.where_sink_consumer_id()
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def update_backfill(backfill, attrs, opts \\ []) do
    Repo.transact(fn ->
      res =
        backfill
        |> Backfill.update_changeset(attrs)
        |> Repo.update()

      with {:ok, backfill} <- res do
        unless opts[:skip_lifecycle] do
          ConsumerLifecycleEventWorker.enqueue(:update, :backfill, backfill.id)
        end

        {:ok, backfill}
      end
    end)
  end

  def create_backfill(attrs, opts \\ []) do
    Repo.transact(fn ->
      res =
        %Backfill{}
        |> Backfill.create_changeset(attrs)
        |> Repo.insert()

      with {:ok, backfill} <- res do
        unless opts[:skip_lifecycle] do
          ConsumerLifecycleEventWorker.enqueue(:create, :backfill, backfill.id)
        end

        {:ok, backfill}
      end
    end)
  end

  def find_backfill(sink_consumer_id, params \\ []) do
    sink_consumer_id
    |> Backfill.where_sink_consumer_id()
    |> backfill_query(params)
    |> Repo.one()
  end

  defp backfill_query(query, params) do
    Enum.reduce(params, query, fn
      {:state, state}, query -> Backfill.where_state(query, state)
      {:limit, limit}, query -> limit(query, ^limit)
      {:order_by, order_by}, query -> order_by(query, ^order_by)
    end)
  end

  def active_backfill_for_consumer(sink_consumer_id) do
    sink_consumer_id
    |> Backfill.where_sink_consumer_id()
    |> Backfill.where_state(:active)
    |> Repo.one()
  end

  defp drop_virtual_fields(message) when is_map(message) do
    Map.drop(message, [
      :dirty,
      :flushed_at,
      :table_reader_batch_id,
      :ingested_at,
      :commit_timestamp,
      :payload_size_bytes,
      :deleted
    ])
  end

  @doc """
  Checks if a message matches a sequence's table.
  """
  @spec matches_sequence?(Sequence.t(), ConsumerRecord.t() | ConsumerEvent.t()) :: boolean()
  def matches_sequence?(%Sequence{} = sequence, message) do
    sequence.table_oid == message.table_oid
  end

  def validate_code(code, opts \\ []) do
    if byte_size(code) > Keyword.get(opts, :maxlen, 2000) do
      [code: "too long"]
    else
      with {:ok, ast} <- Code.string_to_quoted(code),
           {:ok, body} <- Validator.unwrap(ast),
           :ok <- Validator.check(body),
           :ok <- safe_evaluate_code(code) do
        []
      else
        {:error, {location, {_, _} = msg, token}} ->
          msg = "parse error at #{inspect(location)}: #{inspect(msg)} #{token}"
          [code: msg]

        {:error, {location, msg, token}} ->
          msg = "parse error at #{inspect(location)}: #{msg} #{token}"
          [code: msg]

        {:error, :validator, msg} ->
          [code: "validation failed: #{msg}"]

        {:error, :evaluation_error, %CompileError{} = error} ->
          [code: "code failed to evaluate: #{Exception.message(error)}"]

        # We ignore other runtime errors because the synthetic message
        # might cause ie. bad arithmetic errors whereas the users' real
        # data might be ok.
        {:error, :evaluation_error, _} ->
          []
      end
    end
  end

  def safe_evaluate_code(code) do
    Message.to_external(
      %SinkConsumer{id: nil, transform: %Transform{transform: %FunctionTransform{code: code}}},
      synthetic_message()
    )

    :ok
  rescue
    error ->
      {:error, :evaluation_error, error}
  end

  def synthetic_message do
    %ConsumerEvent{
      data: %ConsumerEventData{
        record: %{
          "id" => 1,
          "name" => "Paul Atreides",
          "house" => "Fremen",
          "inserted_at" => DateTime.utc_now()
        },
        changes: %{"house" => "House Atreides"},
        action: :update,
        metadata: %Metadata{
          table_schema: "public",
          table_name: "characters",
          commit_timestamp: DateTime.utc_now(),
          commit_lsn: 309_018_972_104,
          database_name: "dune",
          transaction_annotations: nil,
          consumer: %Metadata.Sink{
            id: Sequin.uuid4(),
            name: "my-consumer"
          }
        }
      }
    }
  end
end
