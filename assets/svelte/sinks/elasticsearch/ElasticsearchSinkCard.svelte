<script lang="ts">
  import { ExternalLink } from "lucide-svelte";
  import { Card, CardContent } from "$lib/components/ui/card";
  import { Button } from "$lib/components/ui/button";
  import type { ElasticsearchConsumer } from "../../consumers/types";

  export let consumer: ElasticsearchConsumer;
</script>

<Card>
  <CardContent class="p-6">
    <div class="flex justify-between items-center mb-4">
      <h2 class="text-lg font-semibold">Elasticsearch Configuration</h2>
    </div>

    <div class="grid grid-cols-2 gap-4">
      <div>
        <span class="text-sm text-gray-500">Endpoint URL</span>
        <div class="mt-2">
          <div
            class="font-mono bg-slate-50 pl-1 pr-4 py-1 border border-slate-100 rounded-md break-all w-fit"
          >
            <span>{consumer.sink.endpoint_url}</span>
          </div>
        </div>
      </div>

      <div>
        <span class="text-sm text-gray-500">Index Name</span>
        <div class="mt-2">
          <span
            class="font-mono bg-slate-50 pl-1 pr-4 py-1 border border-slate-100 rounded-md whitespace-nowrap"
            >{consumer.sink.index_name}</span
          >
        </div>
      </div>
    </div>
  </CardContent>
</Card>
