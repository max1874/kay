<script lang="ts">
  // Which service Kay dictates with, and its key. Services with a key come first; picking one switches on the spot,
  // after a test if it hasn't passed one since launch. Picking one without a key shows its key form, and it becomes
  // the one dictation uses once its key passes the test; until then dictation stays where it was, and this says so.
  import Confirm from './Confirm.svelte';
  import Status from './Status.svelte';
  import {
    call, DEFAULT_WORKSPACE_URL, doubaoResources, kay, openURL, providers, providerState, t, type Provider,
  } from './kay.svelte';

  /// The service whose key form is shown.
  let shown = $state<Provider>(kay.snapshot.provider);
  let draft = $state('');
  let settingDraft = $state(providerState(kay.snapshot.provider).setting);
  let confirmRemove = $state(false);

  const s = $derived(kay.snapshot);
  const state = $derived(providerState(shown));
  const info = $derived(providers[shown]);
  const testing = $derived(state.status.kind === 'testing');
  const changed = $derived(draft.trim() !== '' || settingDraft.trim() !== state.setting);
  const ordered = $derived([...s.providers.filter((p) => p.hasKey), ...s.providers.filter((p) => !p.hasKey)]);

  // When dictation switches service (from the window's menu, or a test here), the form follows.
  let following = kay.snapshot.provider;
  $effect(() => {
    if (s.provider !== following) {
      following = s.provider;
      show(s.provider);
    }
  });

  function show(provider: Provider) {
    if (provider === shown && settingDraft) return;
    shown = provider;
    draft = '';
    settingDraft = providerState(provider).setting;
  }

  function choose(provider: Provider) {
    show(provider);
    call('select_provider', { provider });
  }

  async function test() {
    const provider = shown;
    if (!draft.trim() && !state.hasKey) return;
    await call('test_provider', { provider, key: draft.trim() || null, setting: settingDraft });
    const after = providerState(provider);
    if (after.status.kind === 'connected' && !after.candidateError && shown === provider) draft = '';
  }

  const clear = () => state.candidateError && call('clear_candidate_error', { provider: shown });
  const link = (url: string) => (e: MouseEvent) => (e.preventDefault(), openURL(url));
</script>

<div class="pane form">
  <h1>{t('Speech Service')}</h1>

  <section>
    <div class="card">
      <label class="row">
        <span>{t('Dictate With')}</span>
        <select value={shown} onchange={(e) => choose(e.currentTarget.value as Provider)}>
          {#each ordered as p (p.provider)}
            <option value={p.provider}>{t(providers[p.provider].name)}{p.hasKey ? '' : ` (${t('Not Set')})`}</option>
          {/each}
        </select>
      </label>
      <div class="row">
        <span class="stack"><strong>{t(info.name)}</strong><span class="secondary small">{t(info.model)}</span></span>
        <Status {state} badge />
      </div>
      {#if shown !== s.provider}
        <p class="row secondary small">{t('Kay keeps dictating with {} until this key passes the test.', t(providers[s.provider].name))}</p>
      {/if}
    </div>
    <p class="footer">
      {t("Kay uses your own account with each service. Audio goes straight from this PC to the one you choose, keys stay in Windows Credential Manager, and each service bills you at its standard rates. You can also switch from the menu under the status line in Kay's window.")}
    </p>
  </section>

  <section>
    <h3>{t('API Key')}</h3>
    <form class="card" onsubmit={(e) => (e.preventDefault(), test())}>
      <label class="row">
        <span>{t('API Key')}</span>
        <input type="password" autocomplete="off" bind:value={draft} oninput={clear}
          placeholder={state.maskedKey ? t('Saved ({}). Paste a new key to replace it.', state.maskedKey) : t(info.prompt)} />
      </label>
      {#if shown === 'qwen'}
        <label class="row">
          <span>{t('Workspace URL')}</span>
          <input type="url" bind:value={settingDraft} oninput={clear} placeholder={DEFAULT_WORKSPACE_URL} />
        </label>
      {:else}
        <label class="row">
          <span>{t('Resource')}</span>
          <select bind:value={settingDraft} onchange={clear}>
            {#each doubaoResources as [id, title] (id)}<option value={id}>{t(title)} · {id}</option>{/each}
          </select>
        </label>
      {/if}
      <div class="row start">
        <button class="primary" type="submit" disabled={testing || (!draft.trim() && !state.hasKey)}>
          {#if testing}<span class="spinner"></span>{:else}{state.hasKey && !changed ? t('Test Again') : t('Test & Save')}{/if}
        </button>
        <Status {state} ready />
      </div>
    </form>
    <p class="footer links">
      <span>{t(info.hint)}</span>
      <a href={info.keysURL} onclick={link(info.keysURL)}>{t('Get an API Key ↗')}</a>
      <a href={info.consoleURL} onclick={link(info.consoleURL)}>{t(info.console)}</a>
    </p>
  </section>

  {#if state.hasKey}
    <section><button class="danger" onclick={() => (confirmRemove = true)}>{t('Remove Key…')}</button></section>
  {/if}
</div>

<Confirm bind:open={confirmRemove} title={t('Remove this key from Kay?')} action={t('Remove')}
  onconfirm={() => call('remove_provider_key', { provider: shown })}>{t(info.revoke)}</Confirm>
