<script lang="ts">
  // Says whether Kay can dictate, and gives back what you said: status and usage on top, then every dictation as a
  // card, newest first, grouped by day. Click one to copy it again.
  import Icon from './Icon.svelte';
  import Microphone from './Microphone.svelte';
  import {
    call, isUsable, kay, openURL, providers, providerState, statusSummary, t, triggerNames,
    type Entry, type Pane, type Provider,
  } from './kay.svelte';

  let { go }: { go: (pane: Pane) => void } = $props();
  let query = $state('');
  let copied = $state<string | null>(null);

  const s = $derived(kay.snapshot);
  const current = $derived(providerState(s.provider));
  const searching = $derived(query.trim() !== '');
  const locale = $derived(s.chinese ? 'zh-CN' : 'en');

  const sections = $derived.by(() => {
    const q = query.trim().toLocaleLowerCase();
    const days = new Map<string, Entry[]>();
    for (const entry of kay.history) {
      if (q && !entry.text.toLocaleLowerCase().includes(q)) continue;
      const day = dayTitle(new Date(entry.date));
      if (!days.has(day)) days.set(day, []);
      days.get(day)!.push(entry);
    }
    return [...days];
  });

  const today = () => new Date().toDateString();
  const stats = $derived({
    today: kay.history.filter((e) => !e.error && new Date(e.date).toDateString() === today()).length,
    characters: kay.history.reduce((sum, e) => sum + e.text.replace(/[\s\p{P}]/gu, '').length, 0),
    audio: kay.history.reduce((sum, e) => sum + e.audioSeconds, 0),
  });

  const headline = $derived(
    s.state === 'recording' ? t('Listening…')
      : s.state === 'processing' ? t('Recognizing…')
      : s.ready ? t('Hold {} to Dictate', triggerNames())
      : t('Finish Setting Up Kay'),
  );

  /// The first trigger as printed on the key: "Alt" with "Right" under it; several keys as their names.
  const keycap = $derived.by(() => {
    const [mask, name] = s.triggers[0];
    const parts = name.split(' ');
    return (mask & (mask - 1)) === 0 && parts.length === 2 ? { key: parts[1], side: parts[0] } : { key: name, side: '' };
  });

  function dayTitle(date: Date): string {
    const yesterday = new Date();
    yesterday.setDate(yesterday.getDate() - 1);
    if (date.toDateString() === today()) return t('Today');
    if (date.toDateString() === yesterday.toDateString()) return t('Yesterday');
    const year = date.getFullYear() === new Date().getFullYear() ? undefined : 'numeric';
    return date.toLocaleDateString(locale, { weekday: 'long', month: 'long', day: 'numeric', year });
  }

  const time = (iso: string) => new Date(iso).toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' });
  const clock = (seconds: number) => `${Math.floor(seconds / 60)}:${String(Math.round(seconds % 60)).padStart(2, '0')}`;

  function duration(seconds: number): string {
    if (seconds < 60) return t('{} s', Math.round(seconds));
    const minutes = Math.round(seconds / 60);
    return minutes < 60 ? t('{} min', minutes) : t('{} h {} min', Math.floor(minutes / 60), minutes % 60);
  }

  async function copy(entry: Entry) {
    if (!entry.text || !(await call<boolean>('copy_text', { text: entry.text }))) return;
    copied = entry.id;
    setTimeout(() => copied === entry.id && (copied = null), 1200);
  }

  function engine(e: Event) {
    const value = (e.currentTarget as HTMLSelectElement).value;
    if (value === 'settings') {
      (e.currentTarget as HTMLSelectElement).value = s.provider;
      go('speech');
    } else {
      call('select_provider', { provider: value });
    }
  }
</script>

<div class="pane">
  <div class="search">
    <Icon name="search" />
    <input type="search" placeholder={t('Search Dictations')} bind:value={query} />
  </div>

  {#if !searching}
    <header class="status">
      <div class="keycap" class:active={s.ready} class:recording={s.state === 'recording'}>
        <span class="key">{keycap.key}</span>
        {#if keycap.side}<span class="side">{keycap.side}</span>{/if}
      </div>
      <div class="lines">
        <h1>{headline}</h1>
        <p class="secondary">{t('Speak while you hold it. Let go, and the text appears where your cursor is, in any app.')}</p>
        {#if s.ready}
          <p class="secondary small ok">
            <Icon name="check-circle" />
            {statusSummary(current, s.provider)} ·
            <a href={providers[s.provider].consoleURL} onclick={(e) => (e.preventDefault(), openURL(providers[s.provider].consoleURL))}>
              {t(providers[s.provider].console)}
            </a>
          </p>
        {/if}
        <div class="menus">
          <label><Icon name="mic" /><Microphone compact /></label>
          <label title={t('The speech service Kay dictates with. Each one uses its own key.')}>
            <Icon name="speech" />
            <select class="compact" value={s.provider} onchange={engine}>
              {#each s.providers.filter((p) => p.hasKey || p.provider === s.provider) as p (p.provider)}
                <option value={p.provider}>{t(providers[p.provider as Provider].short)}</option>
              {/each}
              <option value="settings">{t('Speech Service Settings…')}</option>
            </select>
          </label>
        </div>
      </div>
    </header>

    {#if !s.ready}
      <div class="setup">
        <div class="card setup-card">
          <span class="tile big" style:background="#d13438"><Icon name="mic" size={18} /></span>
          <div><h3>{t('Microphone')}</h3><p class="secondary">{t('Kay records only while you hold the key.')}</p></div>
          {#if s.microphoneAllowed}
            <span class="done"><Icon name="check-circle" size={22} /></span>
          {:else}
            <button class="primary" onclick={() => openURL('ms-settings:privacy-microphone')}>{t('Open Windows Settings')}</button>
          {/if}
        </div>
        <div class="card setup-card">
          <span class="tile big" style:background="#8a4fd8"><Icon name="key" size={18} /></span>
          <div><h3>{t('Speech Service')}</h3><p class="secondary">{statusSummary(current, s.provider)}</p></div>
          {#if isUsable(current.status)}
            <span class="done"><Icon name="check-circle" size={22} /></span>
          {:else}
            <button class="primary" onclick={() => go('speech')}>{t('Add API Key')}</button>
          {/if}
        </div>
      </div>
    {/if}

    <div class="stats">
      <div class="card stat"><strong>{stats.today}</strong><span>{t('Dictations Today')}</span></div>
      <div class="card stat"><strong>{stats.characters.toLocaleString(locale)}</strong><span>{t('Characters')}</span></div>
      <div class="card stat"><strong>{duration(stats.audio)}</strong><span>{t('Audio Sent')}</span></div>
    </div>
  {/if}

  {#if kay.history.length === 0}
    <p class="empty card">{t('No dictations yet. Hold {} and say something.', triggerNames())}</p>
  {:else if sections.length === 0}
    <p class="empty">{t('No dictations match “{}”.', query.trim())}</p>
  {:else}
    {#each sections as [day, entries] (day)}
      <h2 class="day">{day}</h2>
      {#each entries as entry (entry.id)}
        <div class="card entry" class:failed={entry.error}>
          <button class="text" onclick={() => copy(entry)} disabled={!entry.text} title={entry.text ? t('Copy') : ''}>
            {#if entry.error}<Icon name="warning" /> {entry.error}{:else}{entry.text}{/if}
          </button>
          <div class="meta secondary small">
            <span>{time(entry.date)}</span>
            <span>{clock(entry.audioSeconds)}</span>
            {#if copied === entry.id}<span class="ok"><Icon name="check" /> {t('Copied')}</span>{/if}
            <span class="spacer"></span>
            <button class="icon" title={t('Delete')} onclick={() => call('delete_entry', { id: entry.id })}>
              <Icon name="trash" />
            </button>
          </div>
        </div>
      {/each}
    {/each}
  {/if}
</div>
