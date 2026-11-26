<script lang="ts" module>
  /// The update requests already answered, across visits to this pane.
  let answered = 0;
</script>

<script lang="ts">
  import Confirm from './Confirm.svelte';
  import Icon from './Icon.svelte';
  import Microphone from './Microphone.svelte';
  import Recorder from './Recorder.svelte';
  import { call, kay, openURL, settings, t } from './kay.svelte';

  let { updateRequests }: { updateRequests: number } = $props();
  let recording = $state(false);
  let confirmClear = $state(false);
  let update = $state<{ checking: boolean; message: string }>({ checking: false, message: '' });

  const s = $derived(kay.snapshot);

  async function checkForUpdates() {
    update = { checking: true, message: '' };
    try {
      const version = await call<string | null>('check_for_updates');
      update = { checking: false, message: version ? t('Installing {}…', version) : t('Kay is up to date.') };
    } catch (error) {
      update = { checking: false, message: t("Couldn't check for updates: {}", String(error)) };
    }
  }

  // The tray's Check for Updates… lands here.
  $effect(() => {
    if (updateRequests > answered) {
      answered = updateRequests;
      checkForUpdates();
    }
  });
</script>

<div class="pane form">
  <h1>{t('General')}</h1>

  <section>
    <h3>{t('Shortcut')}</h3>
    <div class="card">
      {#each s.triggers as [mask, name] (mask)}
        <div class="row">
          <span>{name}</span>
          <button class="icon" title={t('Remove')} disabled={s.triggers.length === 1}
            onclick={() => settings({ triggers: s.settings.triggers.filter((m) => m !== mask) })}>
            <Icon name="minus" />
          </button>
        </div>
      {/each}
      <div class="row"><button onclick={() => (recording = true)}>{t('Add Key…')}</button></div>
    </div>
    <p class="footer">
      {t('Holding any key in the list dictates, so each keyboard can use its own. Pressing any other key while you hold it cancels the recording, so shortcuts that use the same key keep working.')}
    </p>
  </section>

  <section>
    <h3>{t('Recording')}</h3>
    <div class="card"><div class="row"><span>{t('Microphone')}</span><Microphone /></div></div>
    <p class="footer">{t("When the chosen microphone isn't connected, Kay records from the system default.")}</p>
  </section>

  <section>
    <h3>{t('Pasting')}</h3>
    <div class="card">
      <label class="row">
        <span>{t('Show in Clipboard History')}</span>
        <input type="checkbox" class="switch" checked={s.settings.showInClipboardHistory}
          onchange={(e) => settings({ showInClipboardHistory: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{t('Pause Music and Videos')}</span>
        <input type="checkbox" class="switch" checked={s.settings.pauseMedia}
          onchange={(e) => settings({ pauseMedia: e.currentTarget.checked })} />
      </label>
    </div>
    <p class="footer">
      {t('Kay pastes through the clipboard and then puts back what was there. When Show in Clipboard History is off, Windows clipboard history (Win+V) and clipboard managers leave dictations out. Windows keeps Kay from pasting into apps running as administrator; the text is still in History.')}
    </p>
    <p class="footer">
      {t('While you dictate with the sound coming from speakers, Kay pauses what is playing and plays it again afterwards. With headphones it keeps playing.')}
    </p>
  </section>

  <section>
    <h3>{t('Permissions')}</h3>
    <div class="card">
      <div class="row">
        <span>{t('Microphone')}</span>
        {#if s.microphoneAllowed}
          <span class="ok"><Icon name="check-circle" /> {t('Granted')}</span>
        {:else}
          <button onclick={() => openURL('ms-settings:privacy-microphone')}>{t('Open Windows Settings')}</button>
        {/if}
      </div>
    </div>
  </section>

  <section>
    <h3>{t('App')}</h3>
    <div class="card">
      <label class="row">
        <span>{t('Open at Login')}</span>
        <input type="checkbox" class="switch" checked={s.launchAtLogin}
          onchange={(e) => call('set_launch_at_login', { on: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{t('Show in Notification Area')}</span>
        <input type="checkbox" class="switch" checked={s.settings.trayIcon}
          onchange={(e) => settings({ trayIcon: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{t('Open This Window at Launch')}</span>
        <input type="checkbox" class="switch" checked={s.settings.windowAtLaunch}
          onchange={(e) => settings({ windowAtLaunch: e.currentTarget.checked })} />
      </label>
      <div class="row">
        <span>{t('History')}</span>
        <span class="buttons">
          <button disabled={kay.history.length === 0} onclick={() => call('reveal', { file: 'history' })}>{t('Show in Explorer')}</button>
          <button class="danger" disabled={kay.history.length === 0} onclick={() => (confirmClear = true)}>{t('Clear All…')}</button>
        </span>
      </div>
      <div class="row">
        <span>{t('Version')}</span>
        <span class="buttons">
          <span class="secondary">{update.message || s.version}</span>
          <button disabled={update.checking} onclick={checkForUpdates}>{t('Check for Updates…')}</button>
        </span>
      </div>
    </div>
    {#if !s.settings.windowAtLaunch}
      <p class="footer">{t('Kay starts in the background and waits for the key. Open Kay again from the Start menu to bring this window back.')}</p>
    {/if}
  </section>
</div>

{#if recording}<Recorder bind:open={recording} />{/if}
<Confirm bind:open={confirmClear} title={t('Delete all dictation history?')} action={t('Delete All')}
  onconfirm={() => call('clear_history')}>{t("This can't be undone.")}</Confirm>
