<script lang="ts">
  // The capsule at the bottom center of a fixed, transparent window: level bars while listening, a spinner while
  // recognizing, or a message. Only the capsule changes; the window never does (see hud.rs).
  import { listen } from '@tauri-apps/api/event';
  import { onMount } from 'svelte';
  import Icon, { type IconName } from './Icon.svelte';
  import { call, t } from './kay.svelte';

  type Mode = { mode: 'idle' | 'listening' | 'recognizing' } | { mode: 'message'; text: string; symbol: IconName };

  const BARS = 14;
  let mode = $state<Mode>({ mode: 'idle' });
  let levels = $state<number[]>(Array(BARS).fill(0));
  /// The last one shown, kept through the fade out.
  let shown = $state<Mode>({ mode: 'idle' });

  onMount(() => {
    const show = (next: Mode) => {
      if (next.mode === 'listening') levels = Array(BARS).fill(0);
      mode = next;
      if (next.mode !== 'idle') shown = next;
      // After the fade, nothing is left animating: on the Mac a spinner left running cost 15 % CPU (1.4.2).
      else setTimeout(() => mode.mode === 'idle' && (shown = next), 200);
    };
    listen<Mode>('hud', ({ payload }) => show(payload));
    listen<number>('level', ({ payload }) => (levels = [...levels.slice(1), payload]));
    // A dictation may have started before this page loaded.
    call<Mode>('hud_mode').then(show);
  });
</script>

<div class="capsule" class:visible={mode.mode !== 'idle'}>
  {#if shown.mode === 'listening'}
    <div class="bars">
      {#each levels as level, i (i)}<span style:height="{Math.max(3, level * 18)}px"></span>{/each}
    </div>
  {:else if shown.mode === 'recognizing'}
    <span class="spinner"></span>
    <span class="text">{t('Recognizing…')}</span>
  {:else if shown.mode === 'message'}
    <span class="symbol"><Icon name={shown.symbol} size={15} /></span>
    <span class="text message">{shown.text}</span>
  {/if}
</div>
