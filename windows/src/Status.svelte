<script lang="ts">
  // A key's state: as a badge beside the service, or as the line after Test & Save.
  import Icon from './Icon.svelte';
  import { t, type KeyState } from './kay.svelte';

  let { state, badge = false, ready = false }: { state: KeyState; badge?: boolean; ready?: boolean } = $props();

  const labels = { notSet: 'Not Set', saved: 'Saved', testing: 'Testing…', connected: 'Connected', failed: 'Failed' };
</script>

{#if badge}
  <span class="badge {state.status.kind}">{t(labels[state.status.kind])}</span>
{:else if state.candidateError}
  <span class="message bad"><Icon name="x" /> {state.candidateError}</span>
{:else if state.status.kind === 'connected'}
  <span class="message ok">
    <Icon name="check-circle" />
    {ready ? t('Connected · {} ms. Ready to dictate.', state.status.ms) : t('Connected · {} ms', state.status.ms)}
  </span>
{:else if state.status.kind === 'failed'}
  <span class="message bad"><Icon name="x" /> {state.status.message}</span>
{/if}
