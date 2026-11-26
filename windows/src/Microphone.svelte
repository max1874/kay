<script lang="ts">
  // Which microphone dictation records from, remembered by endpoint ID. A chosen one that is unplugged stays chosen,
  // and listed, until it's back; meanwhile the system default records. Read again whenever the window comes forward.
  import { onMount } from 'svelte';
  import { call, kay, settings, t } from './kay.svelte';

  let { compact = false }: { compact?: boolean } = $props();
  let devices = $state<{ id: string; name: string }[]>([]);
  let defaultName = $state<string | null>(null);

  async function reload() {
    const found = await call<{ devices: typeof devices; defaultName: string | null }>('microphones');
    devices = found.devices;
    defaultName = found.defaultName;
  }

  onMount(() => {
    reload();
    window.addEventListener('focus', reload);
    return () => window.removeEventListener('focus', reload);
  });

  const chosen = $derived(kay.snapshot.settings.microphone);
  const systemDefault = $derived(defaultName ? t('System Default ({})', defaultName) : t('System Default'));
</script>

<select class:compact value={chosen} onchange={(e) => settings({ microphone: e.currentTarget.value })}
  title={t("When the chosen microphone isn't connected, Kay records from the system default.")}>
  <option value="">{systemDefault}</option>
  {#each devices as device (device.id)}
    <option value={device.id}>{device.name}</option>
  {/each}
  {#if chosen && !devices.some((d) => d.id === chosen)}
    <option value={chosen}>{t('Not Connected')}</option>
  {/if}
</select>
