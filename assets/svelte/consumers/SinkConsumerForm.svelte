<script lang="ts">
  import { Button } from "$lib/components/ui/button";
  import { Input } from "$lib/components/ui/input";
  import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
  } from "$lib/components/ui/select";
  import {
    Card,
    CardContent,
    CardHeader,
    CardTitle,
  } from "$lib/components/ui/card";
  import { Label } from "$lib/components/ui/label";
  import FullPageModal from "../components/FullPageModal.svelte";
  import { cn } from "$lib/utils";
  import FilterForm from "../components/FilterForm.svelte";
  import GroupColumnsForm from "./GroupColumnsForm.svelte";
  import FunctionPicker from "$lib/consumers/FunctionPicker.svelte";
  import SinkHttpPushForm from "$lib/consumers/SinkHttpPushForm.svelte";
  import SqsSinkForm from "$lib/sinks/sqs/SqsSinkForm.svelte";
  import SnsSinkForm from "$lib/sinks/sns/SnsSinkForm.svelte";
  import RedisStreamSinkForm from "$lib/sinks/redis/RedisStreamSinkForm.svelte";
  import KafkaSinkForm from "$lib/sinks/kafka/KafkaSinkForm.svelte";
  import GcpPubsubSinkForm from "$lib/sinks/gcp_pubsub/GcpPubsubSinkForm.svelte";
  import SequinStreamSinkForm from "$lib/sinks/sequin_stream/SequinStreamSinkForm.svelte";
  import NatsSinkForm from "$lib/sinks/nats/NatsSinkForm.svelte";
  import RabbitMqSinkForm from "$lib/sinks/rabbitmq/RabbitMqSinkForm.svelte";
  import AzureEventHubSinkForm from "$lib/sinks/azure_event_hub/AzureEventHubSinkForm.svelte";
  import { CircleAlert, Info, ChevronDown, Plus } from "lucide-svelte";
  import TypesenseSinkForm from "$lib/sinks/typesense/TypesenseSinkForm.svelte";
  import ElasticsearchSinkForm from "$lib/sinks/elasticsearch/ElasticsearchSinkForm.svelte";
  import * as Alert from "$lib/components/ui/alert/index.js";
  import TableSelector from "../components/TableSelector.svelte";
  import * as Popover from "$lib/components/ui/popover";
  import * as Dialog from "$lib/components/ui/dialog";
  import MessageExamples from "$lib/components/MessageExamples.svelte";
  import {
    Accordion,
    AccordionContent,
    AccordionItem,
    AccordionTrigger,
  } from "$lib/components/ui/accordion";
  import type { Table as DatabaseTable } from "$lib/databases/types";
  import BackfillForm from "$lib/components/BackfillForm.svelte";
  import { RotateCwIcon, CheckIcon } from "lucide-svelte";
  import Beta from "../components/Beta.svelte";
  import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
  } from "$lib/components/ui/table";

  type Database = {
    id: string;
    name: string;
    tables: DatabaseTable[];
  };

  export let live;
  export let parent;
  export let consumer;
  export let consumerTitle;
  export let httpEndpoints;
  export let databases: Database[];
  export let transforms: Array<{
    id: string;
    name: string;
    type: string;
    description: string;
  }>;
  export let errors: {
    consumer: Record<string, string>;
    sequence: Record<string, string>;
    backfill: Record<string, string>;
  };
  export let isSelfHosted: boolean;

  type MessageKind = "event" | "record";

  interface FormState {
    type: string;
    messageKind: MessageKind;
    maxMemoryMb: number;
    postgresDatabaseId: string | null;
    tableOid: number | null;
    sourceTableFilters: any[];
    sourceTableActions: string[];
    name: string;
    ackWaitMs: number;
    maxAckPending: number;
    maxWaiting: number;
    sink: any;
    runInitialBackfill: boolean;
    backfill: {
      startPosition: "beginning" | "specific" | "none";
      sortColumnAttnum: number | null;
      initialSortColumnValue: string | null;
    };
    groupColumnAttnums: number[];
    batchSize: number;
    transform: string;
    timestampFormat: string;
    routingId: string;
    routingMode: string;
  }

  let initialForm: FormState = {
    type: consumer.type,
    messageKind: (consumer.message_kind || "event") as MessageKind,
    maxMemoryMb: Number(consumer.max_memory_mb) || 1024,
    postgresDatabaseId: consumer.postgres_database_id,
    tableOid: consumer.table_oid,
    sourceTableFilters: consumer.source_table_filters || [],
    sourceTableActions: consumer.source_table_actions || [],
    name: consumer.name || "",
    ackWaitMs: Number(consumer.ack_wait_ms) || 30000,
    maxAckPending: Number(consumer.max_ack_pending) || 10000,
    maxWaiting: Number(consumer.max_waiting) || 20,
    sink: consumer.sink,
    runInitialBackfill: false,
    backfill: {
      startPosition: "none",
      sortColumnAttnum: null,
      initialSortColumnValue: null,
    },
    groupColumnAttnums: consumer.group_column_attnums || [],
    batchSize: Number(consumer.batch_size) || 1,
    transform: consumer.transform_id || "none",
    timestampFormat: consumer.timestamp_format || "iso8601",
    routingId: consumer.routing_id || "none",
    routingMode: consumer.routing_mode,
  };

  let form: FormState = { ...initialForm };
  let lastPushedFormJSON = null;
  let isDirty = false;
  let isSubmitting = false;

  type TestConnectionState = {
    status: "initial" | "loading" | "success" | "error";
    displayStatus?: boolean;
    error?: string;
    lastTestStatus?: "success" | "error" | "none";
  };

  let testConnectionState: TestConnectionState = {
    status: "initial",
    lastTestStatus: "none",
  };

  $: {
    isDirty = JSON.stringify(form) !== JSON.stringify(initialForm);
    // Only push the form if it has changed since the last push
    // Prevents infinite loop of pushing the same form over and over
    if (JSON.stringify(form) !== lastPushedFormJSON) {
      pushEvent("form_updated", { form });
      lastPushedFormJSON = JSON.stringify(form);
    }
  }

  let selectedDatabase: any;
  let selectedTable: any;
  let isCreateConsumerDisabled: boolean = true;

  const pushEvent = (event, payload = {}, cb = (reply: any) => {}) => {
    return live.pushEventTo("#" + parent, event, payload, cb);
  };

  const defaultSortColumnNames = [
    // Updated/Modified columns
    "updated_at",
    "UpdatedAt",
    "updatedAt",
    "last_modified",
    "LastModified",
    "lastModified",
    "last_modified_at",
    "LastModifiedAt",
    "lastModifiedAt",
    "last_updated",
    "lastUpdated",
    "last_updated_at",
    "lastUpdatedAt",
    "modified_at",
    "ModifiedAt",
    "modifiedAt",
    "modified_date",
    "modifiedDate",
    "modified_on",
    "modifiedOn",
    "update_time",
    "updateTime",
    "modification_date",
    "modificationDate",
    "dateModified",
    "dateUpdated",

    // Created/Inserted columns
    "created_at",
    "CreatedAt",
    "createdAt",
    "inserted_at",
    "InsertedAt",
    "insertedAt",
    "creation_date",
    "CreationDate",
    "creationDate",
    "creation_time",
    "create_time",
    "createTime",
    "created_date",
    "created_on",
    "DateCreated",
    "dateCreated",
    "insert_date",
    "insert_time",
    "insertTime",
    "timestamp",
  ];

  $: {
    if (form.postgresDatabaseId) {
      selectedDatabase = databases.find(
        (db) => db.id === form.postgresDatabaseId,
      );
    }

    if (form.tableOid && selectedDatabase) {
      selectedTable = selectedDatabase.tables.find(
        (table) => table.oid === form.tableOid,
      );
    }

    if (selectedTable) {
      // Force message kind to "record" for event tables
      if (selectedTable.is_event_table) {
        form.messageKind = "record";
      }
    }

    isCreateConsumerDisabled = !form.postgresDatabaseId || !form.tableOid;
  }

  const isEditMode = !!consumer.id;
  let dialogOpen = true;
  let showConfirmDialog = false;

  function handleConsumerSubmit() {
    isSubmitting = true;
    pushEvent("form_submitted", { form }, (reply) => {
      if (reply?.ok !== true) {
        isSubmitting = false;
      }
    });
  }

  function handleTableSelect(event: { databaseId: string; tableOid: number }) {
    if (form.tableOid !== event.tableOid) {
      form.groupColumnAttnums = [];
      form.messageKind = "event";
    }

    form.postgresDatabaseId = event.databaseId;
    form.tableOid = event.tableOid;

    // Set the form name based on the selected table
    if (form.tableOid) {
      const selectedDatabase = databases.find(
        (db) => db.id === form.postgresDatabaseId,
      );
      if (selectedDatabase) {
        const selectedTable = selectedDatabase.tables.find(
          (table) => table.oid === form.tableOid,
        );
        if (selectedTable) {
          const tableName = selectedTable.name;
          const newName = `${tableName}_sink`;
          form.name = newName;
        }
      }
    }
  }

  function handleFilterChange(newFilters) {
    form.sourceTableFilters = newFilters;
  }

  function handleClose() {
    pushEvent("form_closed");
  }

  let showLocalhostWarningDialog = false;
  let dismissedLocalhostWarning = false;

  function onTestConnection() {
    // Add check for localhost in sink configuration
    const sinkConfig = form.sink;
    let hasLocalhost = false;

    if (sinkConfig) {
      const configStr = JSON.stringify(sinkConfig).toLowerCase();
      hasLocalhost =
        configStr.includes("localhost") || configStr.includes("127.0.0.1");
    }

    if (hasLocalhost && !dismissedLocalhostWarning) {
      showLocalhostWarningDialog = true;
    } else {
      runConnectionTest();
    }
  }

  function runConnectionTest() {
    testConnectionState = {
      status: "loading",
      lastTestStatus: testConnectionState.lastTestStatus,
    };

    pushEvent("test_connection", {}, (reply) => {
      if (reply.ok) {
        testConnectionState = {
          displayStatus: true,
          status: "success",
          lastTestStatus: "success",
        };
        setTimeout(() => {
          testConnectionState = {
            status: "initial",
            lastTestStatus: "success",
          };
        }, 3000);
      } else {
        testConnectionState = {
          displayStatus: true,
          status: "error",
          error: reply.error,
          lastTestStatus: "error",
        };
        setTimeout(() => {
          testConnectionState.displayStatus = false;
          testConnectionState.status = "initial";
        }, 3000);
      }
    });
  }

  let backfillSectionExpanded = false;
  let showMessageTypeExampleModal = false;
  let selectedExampleType: "change" | "record" = "change";

  let transformSectionExpanded = false;

  let transformRefreshState: "idle" | "refreshing" | "done" = "idle";

  function refreshFunctions() {
    transformRefreshState = "refreshing";
    pushEvent("refresh_transforms", {}, () => {
      transformRefreshState = "done";
      setTimeout(() => {
        transformRefreshState = "idle";
      }, 2000);
    });
  }

  const exampleIsoTimestamp = "2025-01-01T00:00:00.000000Z";
  const exampleUnixMicrosecondTimestamp = 1704086400000000;
</script>

<FullPageModal
  title={isEditMode ? `Edit ${consumerTitle}` : `Create ${consumerTitle}`}
  bind:open={dialogOpen}
  bind:showConfirmDialog
  showConfirmOnExit={isDirty}
  on:close={handleClose}
>
  <form
    on:submit|preventDefault={handleConsumerSubmit}
    class="space-y-6 max-w-3xl mx-auto mt-6"
  >
    <Card>
      <CardHeader>
        <CardTitle>Source</CardTitle>
      </CardHeader>
      <CardContent class="space-y-4">
        <div class="space-y-2">
          {#if isEditMode}
            <Select
              disabled
              selected={{
                value: form.postgresDatabaseId,
                label: selectedDatabase?.name || "Selected database",
              }}
            >
              <SelectTrigger
                class={cn(
                  "w-full",
                  "bg-muted text-muted-foreground opacity-100",
                )}
              >
                <SelectValue placeholder="Selected database" />
              </SelectTrigger>
            </Select>
            <Select
              disabled
              selected={{
                value: form.tableOid,
                label: selectedTable?.name || "Selected table",
              }}
            >
              <SelectTrigger
                class={cn(
                  "w-full",
                  "bg-muted text-muted-foreground opacity-100",
                )}
              >
                <SelectValue placeholder="Selected table" />
              </SelectTrigger>
            </Select>
          {:else}
            <TableSelector
              {databases}
              onSelect={handleTableSelect}
              {pushEvent}
              selectedDatabaseId={form.postgresDatabaseId}
              selectedTableOid={form.tableOid}
            />

            {#if errors.consumer.postgres_database_id}
              <p class="text-destructive text-sm">
                {errors.consumer.postgres_database_id}
              </p>
            {/if}

            {#if errors.consumer.table_oid}
              <p class="text-destructive text-sm">
                {errors.consumer.table_oid}
              </p>
            {/if}
          {/if}
          {#if selectedTable}
            <div class="space-y-2">
              <Label for="message_kind">Message type</Label>
              <p class="text-sm text-muted-foreground mt-1 mb-2">
                Select the kind of messages you want to process.
                <button
                  type="button"
                  class="text-muted-foreground underline decoration-dotted"
                  on:click={() => (showMessageTypeExampleModal = true)}
                >
                  See examples
                </button>
              </p>
              <Select
                selected={{
                  value: form.messageKind,
                  label: form.messageKind === "record" ? "Records" : "Changes",
                }}
                onSelectedChange={(event) => {
                  form.messageKind = event.value;
                }}
                disabled={selectedTable.is_event_table || isEditMode}
              >
                <SelectTrigger>
                  <SelectValue placeholder="Select a message type" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="event">Changes</SelectItem>
                  <SelectItem value="record">Records</SelectItem>
                </SelectContent>
              </Select>
              {#if selectedTable.is_event_table}
                <p class="text-muted-foreground text-xs">
                  Sequin automatically sets the message type to "Records" for
                  event tables.
                </p>
              {/if}
              {#if errors.consumer.message_kind}
                <p class="text-destructive text-sm">
                  {errors.consumer.message_kind}
                </p>
              {/if}
            </div>
          {/if}
          {#if errors.consumer.postgres_database_id || errors.consumer.table_oid}
            <p class="text-destructive text-sm">
              {errors.consumer.postgres_database_id ||
                errors.consumer.table_oid}
            </p>
          {/if}
        </div>
      </CardContent>
    </Card>

    <Card>
      <CardHeader>
        <CardTitle>Filters</CardTitle>
      </CardHeader>
      <CardContent>
        <FilterForm
          messageKind={form.messageKind}
          {selectedTable}
          bind:form
          {errors}
          onFilterChange={handleFilterChange}
          showTitle={false}
          isEdit={isEditMode}
        />
      </CardContent>
    </Card>

    <Card>
      <CardHeader class="flex flex-row items-center justify-between">
        <CardTitle class="flex items-center gap-2">
          Transforms
          <Popover.Root>
            <Popover.Trigger asChild let:builder>
              <Button
                builders={[builder]}
                variant="link"
                class="text-muted-foreground hover:text-foreground p-0"
              >
                <Info class="h-4 w-4" />
              </Button>
            </Popover.Trigger>
            <Popover.Content class="w-80">
              <div class="grid gap-4">
                <div class="space-y-2">
                  <p class="text-sm text-muted-foreground font-normal">
                    Transform your messages before they are sent to the sink
                    destination.
                  </p>
                </div>
              </div>
            </Popover.Content>
          </Popover.Root>
          <Beta size="sm" variant="subtle" />
        </CardTitle>
        {#if consumer.type !== "redis_stream"}
          <button
            type="button"
            class="flex items-center space-x-2 text-sm hover:text-primary transition-colors disabled:opacity-50"
            on:click={() =>
              (transformSectionExpanded = !transformSectionExpanded)}
            disabled={!selectedTable}
          >
            <div
              class="transition-transform duration-200"
              class:rotate-180={transformSectionExpanded}
            >
              <ChevronDown class="h-4 w-4" />
            </div>
          </button>
        {/if}
      </CardHeader>

      <CardContent>
        <div class="space-y-2">
          {#if consumer.type === "redis_stream"}
            <p class="text-sm text-muted-foreground">
              Transforms are coming soon for Redis Stream sinks. <a
                href="https://github.com/sequinstream/sequin/issues/1186"
                target="_blank"
                rel="noopener noreferrer"
                class="text-primary underline">Let us know</a
              > if you want this.
            </p>
          {:else if !transformSectionExpanded}
            <p class="text-sm text-muted-foreground">
              {#if form.transform === "none"}
                No transform. Messages will be sent as-is to the sink
                destination.
              {:else}
                <div class="font-medium">
                  {transforms.find((t) => t.id === form.transform)?.name ||
                    form.transform}
                </div>
                <div class="text-sm text-muted-foreground">
                  {transforms.find((t) => t.id === form.transform)
                    ?.description || ""}
                </div>
              {/if}
            </p>
          {:else if !selectedTable}
            <p class="text-sm text-muted-foreground">
              Please select a table first.
            </p>
          {:else}
            <FunctionPicker
              {transforms}
              selectedFunctionId={form.transform}
              title="Transform"
              onFunctionChange={(transformId) => (form.transform = transformId)}
              {refreshFunctions}
              transformTypes={["function", "path"]}
              createNewQueryParams="?type=function"
              bind:refreshState={transformRefreshState}
            />
          {/if}
        </div>
      </CardContent>
    </Card>

    {#if !isEditMode}
      <Card>
        <CardHeader class="flex flex-row items-center justify-between">
          <CardTitle class="flex items-center gap-2"
            >Initial backfill
            <Popover.Root>
              <Popover.Trigger asChild let:builder>
                <Button
                  builders={[builder]}
                  variant="link"
                  class="text-muted-foreground hover:text-foreground p-0"
                >
                  <Info class="h-4 w-4" />
                </Button>
              </Popover.Trigger>
              <Popover.Content class="w-80">
                <div class="grid gap-4">
                  <div class="space-y-2">
                    <p class="text-sm text-muted-foreground font-normal">
                      Sequin will run an initial <a
                        href="https://sequinstream.com/docs/reference/backfills"
                        target="_blank"
                        rel="noopener noreferrer"
                        class="text-primary underline"
                      >
                        backfill
                      </a> of data from the selected table to the sink destination.
                    </p>
                  </div>
                </div>
              </Popover.Content>
            </Popover.Root>
          </CardTitle>
          <button
            type="button"
            class="flex items-center space-x-2 text-sm hover:text-primary transition-colors disabled:opacity-50"
            on:click={() =>
              (backfillSectionExpanded = !backfillSectionExpanded)}
            disabled={isEditMode || !selectedTable}
          >
            <div
              class="transition-transform duration-200"
              class:rotate-180={backfillSectionExpanded}
            >
              <ChevronDown class="h-4 w-4" />
            </div>
          </button>
        </CardHeader>
        <CardContent>
          <div class="space-y-2">
            {#if !backfillSectionExpanded}
              <p class="text-sm text-muted-foreground">
                {#if form.backfill.startPosition === "none"}
                  No initial backfill. You can run backfills at any time in the
                  future.
                {:else if form.backfill.startPosition === "beginning"}
                  Backfilling all rows in the table.
                {:else if form.backfill.startPosition === "specific"}
                  Backfilling from:
                  <div class="mt-2">
                    <code>{form.backfill.initialSortColumnValue}</code>
                  </div>
                {/if}
              </p>
            {:else if !selectedTable}
              <p class="text-sm text-muted-foreground">
                Please select a table first.
              </p>
            {:else}
              <BackfillForm
                table={selectedTable}
                form={form.backfill}
                formErrors={errors.backfill}
              />
            {/if}
          </div>
        </CardContent>
      </Card>
    {/if}

    <GroupColumnsForm
      errors={errors.consumer}
      {isEditMode}
      {selectedTable}
      bind:groupColumnAttnums={form.groupColumnAttnums}
      infoText={consumer.type === "kafka"
        ? "For Kafka sinks, the group column values are joined with ':' delimiters to generate the message key. Messages are published using hash partitioning on the message key."
        : null}
    />

    {#if consumer.type === "http_push"}
      <SinkHttpPushForm
        errors={errors.consumer}
        {httpEndpoints}
        bind:form
        {live}
        {parent}
        {transforms}
        {refreshFunctions}
        bind:transformRefreshState
      />
    {:else if consumer.type === "sqs"}
      <SqsSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "sns"}
      <SnsSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "redis_stream"}
      <RedisStreamSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "kafka"}
      <KafkaSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "gcp_pubsub"}
      <GcpPubsubSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "sequin_stream"}
      <SequinStreamSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "nats"}
      <NatsSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "rabbitmq"}
      <RabbitMqSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "azure_event_hub"}
      <AzureEventHubSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "typesense"}
      <TypesenseSinkForm errors={errors.consumer} bind:form />
    {:else if consumer.type === "elasticsearch"}
      <ElasticsearchSinkForm errors={errors.consumer} bind:form />
    {/if}

    <Card>
      <CardHeader>
        <CardTitle>Sink settings</CardTitle>
      </CardHeader>
      <CardContent class="space-y-4">
        <div class="space-y-2">
          <Label for="consumer-name">Name</Label>
          <div class="flex flex-col gap-1">
            <Input
              id="consumer-name"
              bind:value={form.name}
              placeholder="Enter a unique name for your consumer"
              data-1p-ignore
              data-lpignore="true"
              data-form-type="other"
            />
            <p class="text-xs font-light">
              Must contain only alphanumeric characters, underscores, hyphens,
              or dots.
            </p>
            {#if isEditMode && form.name !== initialForm.name}
              <p class="text-amber-500 text-sm mt-1">
                If you're using YAML to configure Sequin, you may need to change
                the name for this sink in your YAML config file.
              </p>
            {/if}
          </div>
          {#if errors.consumer.name}
            <p class="text-destructive text-sm">{errors.consumer.name}</p>
          {/if}
        </div>

        {#if isSelfHosted}
          <Accordion class="w-full">
            <AccordionItem value="advanced">
              <AccordionTrigger>Advanced configuration</AccordionTrigger>
              <AccordionContent>
                <div class="space-y-4 pt-4">
                  <div class="space-y-2">
                    <Label for="max-memory">Memory limit</Label>
                    <div class="flex flex-col gap-1">
                      <div class="flex items-center gap-2">
                        <Input
                          id="max-memory"
                          type="number"
                          min="128"
                          bind:value={form.maxMemoryMb}
                          class="w-32"
                        />
                        <span class="text-sm text-muted-foreground">MB</span>
                      </div>
                      <p class="text-xs font-light">
                        The soft memory limit for this specific sink. Defaults
                        to 1GB, which is a good starting point.
                      </p>
                    </div>
                    {#if errors.consumer.max_memory_mb}
                      <p class="text-destructive text-sm">
                        {errors.consumer.max_memory_mb}
                      </p>
                    {/if}
                  </div>

                  <div class="space-y-2">
                    <Label for="timestamp-format">Timestamp format</Label>
                    <Select
                      selected={{
                        value: form.timestampFormat,
                        label:
                          form.timestampFormat === "iso8601"
                            ? `ISO8601 string (e.g. ${exampleIsoTimestamp})`
                            : `Unix timestamp (numeric, microseconds, e.g. ${exampleUnixMicrosecondTimestamp})`,
                      }}
                      onSelectedChange={(event) => {
                        form.timestampFormat = event.value;
                      }}
                    >
                      <SelectTrigger id="timestamp-format" class="w-full">
                        <SelectValue placeholder="Select timestamp format" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="iso8601"
                          >ISO8601 string (e.g. {exampleIsoTimestamp})</SelectItem
                        >
                        <SelectItem value="unix_microsecond"
                          >Unix timestamp (numeric, microseconds, e.g. {exampleUnixMicrosecondTimestamp})</SelectItem
                        >
                      </SelectContent>
                    </Select>
                    <p class="text-xs font-light">
                      Choose how timestamps should be formatted in messages sent
                      to your sink.
                    </p>
                    {#if errors.consumer.timestamp_format}
                      <p class="text-destructive text-sm">
                        {errors.consumer.timestamp_format}
                      </p>
                    {/if}
                  </div>
                </div>
              </AccordionContent>
            </AccordionItem>
          </Accordion>
        {/if}

        <div class="flex justify-end items-center gap-2">
          {#if consumer.type !== "http_push" && consumer.type !== "sequin_stream"}
            <Popover.Root bind:open={showLocalhostWarningDialog}>
              <Popover.Trigger />
              <Button
                loading={testConnectionState.status === "loading"}
                variant="outline"
                class="self-end"
                on:click={onTestConnection}
              >
                {#if testConnectionState.status === "success" && testConnectionState.displayStatus}
                  <span
                    class="flex items-center p-1 gap-1 mr-2 bg-green-500 rounded-full"
                  ></span>
                  Connection succeeded
                {:else if testConnectionState.status === "error" && testConnectionState.displayStatus}
                  <span
                    class="flex items-center p-1 gap-1 mr-2 bg-red-500 rounded-full"
                  ></span>
                  Connection failed
                {:else}
                  <span
                    class="flex items-center w-2 h-2 mr-2 rounded-full"
                    class:bg-green-500={testConnectionState.lastTestStatus ===
                      "success"}
                    class:bg-red-500={testConnectionState.lastTestStatus ===
                      "error"}
                    class:bg-gray-300={testConnectionState.lastTestStatus ===
                      "none"}
                  ></span>
                  Test Connection
                {/if}
              </Button>
              <Popover.Content class="w-80">
                <div class="grid gap-4">
                  <div class="space-y-2">
                    <h4 class="font-medium leading-none">
                      Warning: localhost detected
                    </h4>
                    <p class="text-sm text-muted-foreground">
                      Using '<code>localhost</code>' in your configuration may
                      not work as expected. Consider using '<code
                        >host.docker.internal</code
                      >' instead to connect to services running on your machine.
                    </p>
                  </div>
                  <div class="flex justify-end gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      on:click={() => (showLocalhostWarningDialog = false)}
                    >
                      Cancel
                    </Button>
                    <Button
                      size="sm"
                      on:click={() => {
                        dismissedLocalhostWarning = true;
                        showLocalhostWarningDialog = false;
                        runConnectionTest();
                      }}
                    >
                      Test anyway
                    </Button>
                  </div>
                </div>
              </Popover.Content>
            </Popover.Root>
          {/if}
          <Button
            loading={isSubmitting}
            type="submit"
            disabled={isCreateConsumerDisabled}
          >
            {isEditMode ? "Update" : "Create"} Sink
            <span slot="loading"
              >{isEditMode ? "Updating..." : "Creating..."}</span
            >
          </Button>
        </div>
        {#if testConnectionState.lastTestStatus === "error"}
          <Alert.Root variant="destructive">
            <CircleAlert class="h-4 w-4" />
            <Alert.Title>Connection test failed</Alert.Title>
            <Alert.Description>
              {#if typeof testConnectionState.error === "object"}
                <ul
                  class="mt-4"
                  style="font-family: monospace; white-space: pre-wrap; list-style-type: disc; padding-left: 20px;"
                >
                  {#each Object.entries(testConnectionState.error) as [key, value]}
                    <li>{key}: {value}</li>
                  {/each}
                </ul>
              {:else}
                <pre
                  class="mt-4"
                  style="white-space: pre-wrap; word-wrap: break-word;"><code
                    >{testConnectionState.error}</code
                  >
              </pre>
              {/if}
            </Alert.Description>
          </Alert.Root>
        {/if}
      </CardContent>
    </Card>
  </form>
</FullPageModal>

<Dialog.Root bind:open={showMessageTypeExampleModal}>
  <Dialog.Portal>
    <Dialog.Overlay />
    <Dialog.Content class="lg:max-w-5xl md:max-w-3xl p-4">
      <Dialog.Header class="mb-4">
        <Dialog.Title>Message examples</Dialog.Title>
      </Dialog.Header>

      <!-- Mobile view -->
      <div class="lg:hidden space-y-2">
        <div class="mb-4">
          <Select
            selected={{
              value: selectedExampleType,
              label:
                selectedExampleType === "record"
                  ? "Row Messages"
                  : "Change Messages",
            }}
            onSelectedChange={(event) => {
              selectedExampleType = event.value;
            }}
          >
            <SelectTrigger>
              <SelectValue placeholder="Select example type" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="change">Change Messages</SelectItem>
              <SelectItem value="record">Row Messages</SelectItem>
            </SelectContent>
          </Select>
        </div>

        <MessageExamples type={selectedExampleType} />
      </div>

      <!-- Desktop view -->
      <div class="hidden lg:grid grid-cols-2 gap-8">
        <div>
          <h3 class="text-lg font-semibold mb-4">Change Messages</h3>
          <MessageExamples type="change" />
        </div>
        <div>
          <h3 class="text-lg font-semibold mb-4">Row Messages</h3>
          <MessageExamples type="record" />
        </div>
      </div>

      <Dialog.Footer class="mt-4">
        <Button on:click={() => (showMessageTypeExampleModal = false)}
          >Close</Button
        >
      </Dialog.Footer>
      <Dialog.Close />
    </Dialog.Content>
  </Dialog.Portal>
</Dialog.Root>
