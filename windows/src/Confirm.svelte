<script lang="ts">
  // A question before something that can't be undone: the action names itself, Cancel is the default.
  import type { Snippet } from 'svelte';
  import { t } from './kay.svelte';

  let { open = $bindable(), title, action, onconfirm, children }:
    { open: boolean; title: string; action: string; onconfirm: () => void; children?: Snippet } = $props();
  let dialog: HTMLDialogElement;

  $effect(() => {
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  });
</script>

<dialog bind:this={dialog} onclose={() => (open = false)}>
  <h3>{title}</h3>
  {#if children}<p class="secondary">{@render children()}</p>{/if}
  <div class="actions">
    <button onclick={() => (open = false)}>{t('Cancel')}</button>
    <button class="danger" onclick={() => ((open = false), onconfirm())}>{action}</button>
  </div>
</dialog>
