defmodule Sequin.YamlLoaderTest do
  use Sequin.DataCase, async: false

  alias Sequin.Accounts.Account
  alias Sequin.Accounts.User
  alias Sequin.Consumers.HttpEndpoint
  alias Sequin.Consumers.HttpPushConsumer
  alias Sequin.Databases.PostgresDatabase
  alias Sequin.Databases.Sequence
  alias Sequin.Replication.PostgresReplicationSlot
  alias Sequin.Test.Support.ReplicationSlots
  alias Sequin.Test.UnboxedRepo
  alias Sequin.YamlLoader

  @moduletag :unboxed

  @publication "characters_publication"

  def replication_slot, do: ReplicationSlots.slot_name(__MODULE__)

  setup do
    Application.put_env(:sequin, :self_hosted, true)

    # Fast-forward the replication slot to the current WAL position
    :ok = ReplicationSlots.reset_slot(UnboxedRepo, replication_slot())

    :ok
  end

  def playground_yml do
    """
    account:
      name: "Playground"

    users:
      - email: "admin@sequinstream.com"
        password: "sequinpassword!"

    databases:
      - name: "test-db"
        username: "postgres"
        password: "postgres"
        hostname: "localhost"
        database: "sequin_test"
        slot_name: "#{replication_slot()}"
        publication_name: "#{@publication}"

    sequences:
      - name: "characters"
        database: "test-db"
        table_schema: "public"
        table_name: "Characters"
        sort_column_name: "updated_at"
    """
  end

  describe "plan_from_yml" do
    test "returns a list of changesets" do
      assert {:ok, changesets} =
               YamlLoader.plan_from_yml("""
                account:
                  name: "Playground"

                users:
                 - email: "admin@sequinstream.com"
                   password: "sequinpassword!"

                databases:
                  - name: "test-db"
                    username: "postgres"
                    password: "postgres"
                    hostname: "localhost"
                    database: "sequin_test"
                    slot_name: "#{replication_slot()}"
                    publication_name: "#{@publication}"

                sequences:
                  - name: "characters"
                    database: "test-db"
                    table_schema: "public"
                    table_name: "Characters"
                    sort_column_name: "updated_at"

                http_endpoints:
                  - name: "test-endpoint"
                    url: "https://api.example.com/webhook"
               """)

      account_changeset = Enum.find(changesets, &is_struct(&1.data, Account))
      assert account_changeset.action == :create
      assert account_changeset.changes.name == "Playground"

      [user_changeset] = Enum.filter(changesets, &is_struct(&1.data, User))
      assert user_changeset.action == :create
      assert user_changeset.changes.email == "admin@sequinstream.com"

      [database_changeset] = Enum.filter(changesets, &is_struct(&1.data, PostgresDatabase))
      assert database_changeset.action == :create
      assert database_changeset.changes.name == "test-db"

      [sequence_changeset] = Enum.filter(changesets, &is_struct(&1.data, Sequence))
      assert sequence_changeset.action == :create
      assert sequence_changeset.changes.table_schema == "public"
      assert sequence_changeset.changes.table_name == "Characters"
      assert sequence_changeset.changes.sort_column_name == "updated_at"
      assert get_field(sequence_changeset, :postgres_database_id) == database_changeset.data.id

      [http_endpoint_changeset] = Enum.filter(changesets, &is_struct(&1.data, HttpEndpoint))
      assert http_endpoint_changeset.action == :create
      assert http_endpoint_changeset.changes.name == "test-endpoint"
      assert http_endpoint_changeset.changes.scheme == :https
      assert http_endpoint_changeset.changes.host == "api.example.com"
      assert http_endpoint_changeset.changes.path == "/webhook"
      assert http_endpoint_changeset.changes.port == 443
    end

    test "returns invalid changeset for invalid database" do
      assert {:error, [invalid_changeset]} =
               YamlLoader.plan_from_yml("""
               account:
                 name: "Test Account"

               databases:
                 - name: "invalid-db"
               """)

      refute invalid_changeset.valid?

      assert invalid_changeset.errors == [
               database: {"can't be blank", [{:validation, :required}]},
               username: {"can't be blank", [validation: :required]},
               password: {"can't be blank", [validation: :required]}
             ]
    end
  end

  describe "playground.yml" do
    test "creates database and sequence with no existing account" do
      assert :ok = YamlLoader.apply_from_yml!(playground_yml())

      assert [account] = Repo.all(Account)
      assert account.name == "Playground"

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.account_id == account.id
      assert db.name == "test-db"

      assert [%PostgresReplicationSlot{} = replication] = Repo.all(PostgresReplicationSlot)
      assert replication.postgres_database_id == db.id
      assert replication.slot_name == replication_slot()
      assert replication.publication_name == @publication

      assert [%Sequence{} = sequence] = Repo.all(Sequence)
      assert sequence.postgres_database_id == db.id
      assert sequence.table_name == "Characters"
      assert sequence.table_schema == "public"
      assert sequence.sort_column_name == "updated_at"
    end

    test "applying yml twice creates no duplicates" do
      assert :ok = YamlLoader.apply_from_yml!(playground_yml())
      assert :ok = YamlLoader.apply_from_yml!(playground_yml())

      assert [account] = Repo.all(Account)
      assert account.name == "Playground"

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.account_id == account.id
      assert db.name == "test-db"

      assert [%PostgresReplicationSlot{} = replication] = Repo.all(PostgresReplicationSlot)
      assert replication.postgres_database_id == db.id
      assert replication.slot_name == replication_slot()
      assert replication.publication_name == @publication

      assert [%Sequence{} = sequence] = Repo.all(Sequence)
      assert sequence.postgres_database_id == db.id
      assert sequence.table_name == "Characters"
    end
  end

  describe "databases" do
    test "creates a database" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               account:
                 name: "Configured by Sequin"

               databases:
                 - name: "test-db"
                   username: "postgres"
                   password: "postgres"
                   hostname: "localhost"
                   database: "sequin_test"
                   slot_name: "#{replication_slot()}"
                   publication_name: "#{@publication}"
               """)

      assert [account] = Repo.all(Account)
      assert account.name == "Configured by Sequin"

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.account_id == account.id
      assert db.name == "test-db"
    end

    test "updates a database" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               account:
                 name: "Configured by Sequin"

               databases:
                 - name: "test-db"
                   username: "postgres"
                   password: "postgres"
                   hostname: "localhost"
                   database: "sequin_test"
                   slot_name: "#{replication_slot()}"
                   publication_name: "#{@publication}"
               """)

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.pool_size == 3

      assert :ok =
               YamlLoader.apply_from_yml!("""
               account:
                 name: "Configured by Sequin"

               databases:
                 - name: "test-db"
                   username: "postgres"
                   password: "postgres"
                   hostname: "localhost"
                   database: "sequin_test"
                   pool_size: 5
                   slot_name: "#{replication_slot()}"
                   publication_name: "#{@publication}"
               """)

      assert [%PostgresDatabase{} = db] = Repo.all(PostgresDatabase)
      assert db.name == "test-db"
      assert db.pool_size == 5
    end
  end

  describe "http_endpoints" do
    test "creates webhook.site endpoint" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               account:
                 name: "Configured by Sequin"

               http_endpoints:
                 - name: "webhook-endpoint"
                   webhook.site: "true"
               """)

      assert [endpoint] = Repo.all(HttpEndpoint)
      assert endpoint.name == "webhook-endpoint"
      assert endpoint.scheme == :https
      assert endpoint.host == "webhook.site"
      assert "/" <> uuid = endpoint.path
      assert Sequin.String.is_uuid?(uuid)
    end

    test "creates local endpoint" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               account:
                 name: "Configured by Sequin"

               http_endpoints:
                 - name: "local-endpoint"
                   local: "true"
               """)

      assert [endpoint] = Repo.all(HttpEndpoint)
      assert endpoint.name == "local-endpoint"
      assert endpoint.use_local_tunnel == true
      refute endpoint.path
      assert endpoint.headers == %{}
      assert endpoint.encrypted_headers == %{}
    end

    test "creates local endpoint with options" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               account:
                 name: "Configured by Sequin"

               http_endpoints:
                 - name: "local-endpoint"
                   local: "true"
                   path: "/webhook"
                   headers:
                     - key: "X-Test"
                       value: "test-value"
                   encrypted_headers:
                     - key: "X-Secret"
                       value: "secret-value"
               """)

      assert [endpoint] = Repo.all(HttpEndpoint)
      assert endpoint.name == "local-endpoint"
      assert endpoint.use_local_tunnel == true
      assert endpoint.path == "/webhook"
      assert endpoint.headers == %{"X-Test" => "test-value"}
      assert endpoint.encrypted_headers == %{"X-Secret" => "secret-value"}
    end

    test "creates external endpoint" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               account:
                 name: "Configured by Sequin"

               http_endpoints:
                 - name: "external-endpoint"
                   url: "https://api.example.com:8443/webhooks?key=value#fragment"
                   headers:
                     - key: "Authorization"
                       value: "Bearer token"
                   encrypted_headers:
                     - key: "X-Secret"
                       value: "secret-value"
               """)

      assert [endpoint] = Repo.all(HttpEndpoint)
      assert endpoint.name == "external-endpoint"
      assert endpoint.scheme == :https
      assert endpoint.host == "api.example.com"
      assert endpoint.port == 8443
      assert endpoint.path == "/webhooks"
      assert endpoint.query == "key=value"
      assert endpoint.fragment == "fragment"
      assert endpoint.headers == %{"Authorization" => "Bearer token"}
      assert endpoint.encrypted_headers == %{"X-Secret" => "secret-value"}
    end

    test "applying yml twice creates no duplicates" do
      yaml = """
      account:
        name: "Configured by Sequin"

      http_endpoints:
        - name: "test-endpoint"
          url: "https://api.example.com/webhook"
      """

      assert :ok = YamlLoader.apply_from_yml!(yaml)
      assert :ok = YamlLoader.apply_from_yml!(yaml)

      assert [endpoint] = Repo.all(HttpEndpoint)
      assert endpoint.name == "test-endpoint"
    end

    test "validates required fields" do
      assert_raise RuntimeError, ~r/Invalid HTTP endpoint configuration/, fn ->
        YamlLoader.apply_from_yml!("""
        account:
          name: "Configured by Sequin"

        http_endpoints:
          - name: "invalid-endpoint"
        """)
      end
    end
  end

  describe "webhook_subscriptions" do
    def account_db_and_sequence_yml do
      """
      account:
        name: "Configured by Sequin"

      databases:
        - name: "test-db"
          hostname: "localhost"
          database: "sequin_test"
          slot_name: "#{replication_slot()}"
          publication_name: "#{@publication}"

      sequences:
        - name: "characters"
          database: "test-db"
          table_schema: "public"
          table_name: "Characters"
          sort_column_name: "updated_at"
      """
    end

    test "creates basic webhook subscription" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               #{account_db_and_sequence_yml()}

               http_endpoints:
                 - name: "sequin-playground-http"
                   url: "https://api.example.com/webhook"

               webhook_subscriptions:
                 - name: "sequin-playground-webhook"
                   sequence: "characters"
                   http_endpoint: "sequin-playground-http"
                   consumer_start:
                     position: "beginning"
               """)

      assert [consumer] = Repo.all(HttpPushConsumer)
      consumer = Repo.preload(consumer, :sequence)

      assert consumer.name == "sequin-playground-webhook"
      assert consumer.sequence.name == "characters"

      assert %Sequin.Consumers.RecordConsumerState{
               initial_min_cursor: %{1 => 0, 9 => "0001-01-01T00:00:00"},
               producer: :table_and_wal
             } = consumer.record_consumer_state

      assert consumer.sequence_filter == %Sequin.Consumers.SequenceFilter{
               actions: [:insert, :update, :delete],
               column_filters: [],
               group_column_attnums: [1]
             }
    end

    test "creates webhook subscription with filters" do
      assert :ok =
               YamlLoader.apply_from_yml!("""
               #{account_db_and_sequence_yml()}

               http_endpoints:
                 - name: "sequin-playground-http"
                   url: "https://api.example.com/webhook"

               webhook_subscriptions:
                 - name: "sequin-playground-webhook"
                   sequence: "characters"
                   http_endpoint: "sequin-playground-http"
                   filters:
                     - column_name: "house"
                       operator: "="
                       comparison_value: "Stark"
                     - column_name: "name"
                       operator: "is not null"
                     - column_name: "metadata"
                       field_path: "rank.title"
                       operator: "="
                       comparison_value: "Lord"
                       field_type: "string"
                     - column_name: "is_active"
                       operator: "="
                       comparison_value: true
                   consumer_start:
                     position: "end"
               """)

      assert [consumer] = Repo.all(HttpPushConsumer)
      assert consumer.name == "sequin-playground-webhook"

      filters = consumer.sequence_filter.column_filters
      assert length(filters) == 4

      # House filter
      house_filter = Enum.find(filters, &(&1.value.value == "Stark"))
      assert house_filter.operator == :==
      assert house_filter.is_jsonb == false

      # Name filter
      name_filter = Enum.find(filters, &(&1.operator == :not_null))
      assert name_filter.value == %Sequin.Consumers.SequenceFilter.NullValue{value: nil}
      assert name_filter.is_jsonb == false

      # Metadata filter
      metadata_filter = Enum.find(filters, &(&1.jsonb_path == "rank.title"))
      assert metadata_filter.operator == :==
      assert metadata_filter.is_jsonb == true
      assert metadata_filter.value == %Sequin.Consumers.SequenceFilter.StringValue{value: "Lord"}

      # Is active filter
      active_filter = Enum.find(filters, &(&1.value.value == true))
      assert active_filter.operator == :==
      assert active_filter.is_jsonb == false
    end

    test "applying yml twice creates no duplicates" do
      yaml = """
      #{account_db_and_sequence_yml()}

      http_endpoints:
        - name: "sequin-playground-http"
          url: "https://api.example.com/webhook"

      webhook_subscriptions:
        - name: "sequin-playground-webhook"
          sequence: "characters"
          http_endpoint: "sequin-playground-http"
          consumer_start:
            position: "beginning"
      """

      assert :ok = YamlLoader.apply_from_yml!(yaml)
      assert :ok = YamlLoader.apply_from_yml!(yaml)

      assert [consumer] = Repo.all(HttpPushConsumer)
      assert consumer.name == "sequin-playground-webhook"
    end

    test "updates webhook subscription" do
      create_yaml = """
      #{account_db_and_sequence_yml()}

      http_endpoints:
        - name: "sequin-playground-http"
          url: "https://api.example.com/webhook"

      webhook_subscriptions:
        - name: "sequin-playground-webhook"
          sequence: "characters"
          http_endpoint: "sequin-playground-http"
      """

      assert :ok =
               YamlLoader.apply_from_yml!(create_yaml)

      assert [consumer] = Repo.all(HttpPushConsumer)
      consumer = Repo.preload(consumer, :http_endpoint)

      assert consumer.name == "sequin-playground-webhook"
      assert consumer.http_endpoint.name == "sequin-playground-http"

      update_yaml = """
      #{account_db_and_sequence_yml()}

      http_endpoints:
        - name: "new-http-endpoint"
          url: "https://api.example.com/webhook"

      webhook_subscriptions:
        - name: "sequin-playground-webhook"
          sequence: "characters"
          http_endpoint: "new-http-endpoint"
      """

      # Update with different filters
      assert :ok = YamlLoader.apply_from_yml!(update_yaml)

      assert [updated_consumer] = Repo.all(HttpPushConsumer)
      updated_consumer = Repo.preload(updated_consumer, :http_endpoint)

      assert updated_consumer.name == "sequin-playground-webhook"
      assert updated_consumer.http_endpoint.name == "new-http-endpoint"
    end
  end
end
