<script lang="ts">
  // Records a new trigger: the modifier keys pressed together, shown as they go down and kept once all are up, so
  // people see what Windows reports for a key. While this is open, keys don't dictate.
  import { listen } from '@tauri-apps/api/event';
  import { onMount } from 'svelte';
  import { call, kay, settings, t } from './kay.svelte';

  let { open = $bindable() }: { open: boolean } = $props();
  let dialog: HTMLDialogElement;
  let keys = $state({ keys: 0, name: '', complete: false, typed: false });

  const duplicate = $derived(keys.complete && kay.snapshot.settings.triggers.includes(keys.keys));
  const hint = $derived(
    duplicate ? t('This key is already in the list.')
      : keys.typed ? t('Only modifier keys can be held to dictate.')
      : t('Ctrl, Alt, Shift or the Windows key, alone or together. Left and right are different keys.'),
  );

  onMount(() => {
    dialog.showModal();
    call('record_trigger', { on: true });
    const stop = listen<typeof keys>('recorded', ({ payload }) => (keys = payload));
    return () => {
      call('record_trigger', { on: false });
      stop.then((unlisten) => unlisten());
    };
  });

  function add() {
    if (!keys.complete || duplicate) return;
    settings({ triggers: [...kay.snapshot.settings.triggers, keys.keys] });
    open = false;
  }
</script>

<dialog bind:this={dialog} class="recorder" onclose={() => (open = false)}
  onkeydown={(e) => e.key === 'Enter' && (e.preventDefault(), add())}>
  <h3>{t('Press the Key to Hold')}</h3>
  <p class="keys" class:none={!keys.keys}>{keys.keys ? keys.name : '–'}</p>
  <p class="secondary">{hint}</p>
  <div class="actions">
    <button onclick={() => (open = false)}>{t('Cancel')}</button>
    <button class="primary" disabled={!keys.complete || duplicate} onclick={add}>{t('Add')}</button>
  </div>
</dialog>
