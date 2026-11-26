<script lang="ts">
  // The window: a sidebar with your dictations and Kay's settings, and the chosen pane beside it, as on the Mac.
  import { listen } from '@tauri-apps/api/event';
  import Correction from './Correction.svelte';
  import Dictations from './Dictations.svelte';
  import General from './General.svelte';
  import Icon, { type IconName } from './Icon.svelte';
  import { t, type Pane } from './kay.svelte';
  import Speech from './Speech.svelte';

  const panes: { id: Pane; title: string; icon: IconName; tint: string }[] = [
    { id: 'dictations', title: 'Dictations', icon: 'dictations', tint: '#e0457b' },
    { id: 'general', title: 'General', icon: 'general', tint: '#7a7a7a' },
    { id: 'speech', title: 'Speech Service', icon: 'speech', tint: '#8a4fd8' },
    { id: 'correction', title: 'Correction', icon: 'correction', tint: '#1b9aaa' },
  ];

  let pane = $state<Pane>((localStorage.getItem('pane') as Pane | null) ?? 'dictations');
  /// Counts the tray's Check for Updates…, which General answers.
  let updateRequests = $state(0);

  /// The settings pane seen last is the one Settings… opens again.
  function go(next: Pane) {
    pane = next;
    localStorage.setItem('pane', next);
    if (next !== 'dictations') localStorage.setItem('settingsPane', next);
  }

  listen<string>('pane', ({ payload }) => {
    if (payload === 'updates') {
      go('general');
      updateRequests++;
    } else {
      go((localStorage.getItem('settingsPane') as Pane | null) ?? 'general');
    }
  });
</script>

<div class="app">
  <nav>
    {#each panes as p, i (p.id)}
      {#if i === 1}<h2>{t('Settings')}</h2>{/if}
      <button class:selected={pane === p.id} onclick={() => go(p.id)}>
        <span class="tile" style:background={p.tint}><Icon name={p.icon} size={14} /></span>
        {t(p.title)}
      </button>
    {/each}
  </nav>
  <main>
    {#if pane === 'dictations'}
      <Dictations {go} />
    {:else if pane === 'general'}
      <General {updateRequests} />
    {:else if pane === 'speech'}
      <Speech />
    {:else}
      <Correction />
    {/if}
  </main>
</div>
