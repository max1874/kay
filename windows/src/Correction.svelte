<script lang="ts">
  // The switch and DeepSeek key for correction, and the vocabulary, which works without a key.
  import { onMount } from 'svelte';
  import Confirm from './Confirm.svelte';
  import Icon from './Icon.svelte';
  import Status from './Status.svelte';
  import { call, kay, openURL, settings, t } from './kay.svelte';

  const KEYS_URL = 'https://platform.deepseek.com/api_keys';
  const CONSOLE_URL = 'https://platform.deepseek.com/usage';

  let draft = $state('');
  let confirmRemove = $state(false);
  let vocabulary = $state('');
  let saved = $state('');
  let terms = $state(0);
  let failed = $state(false);

  const s = $derived(kay.snapshot);
  const key = $derived(s.correction);
  const testing = $derived(key.status.kind === 'testing');

  onMount(async () => {
    vocabulary = saved = await call<string>('vocabulary');
  });

  $effect(() => {
    call<number>('count_terms', { text: vocabulary }).then((n) => (terms = n));
  });

  async function test() {
    if (!draft.trim() && !key.maskedKey) return;
    await call('test_correction', { key: draft.trim() || null });
    if (kay.snapshot.correction.status.kind === 'connected' && !kay.snapshot.correction.candidateError) draft = '';
  }

  async function save() {
    failed = !(await call<boolean>('save_vocabulary', { text: vocabulary }));
    if (!failed) saved = vocabulary;
  }

  const link = (url: string) => (e: MouseEvent) => (e.preventDefault(), openURL(url));
</script>

<div class="pane form">
  <h1>{t('Correction')}</h1>

  <section>
    <div class="card">
      <label class="row">
        <span>{t('Fix Misheard Words')}</span>
        <input type="checkbox" class="switch" checked={s.settings.correction}
          onchange={(e) => settings({ correction: e.currentTarget.checked })} />
      </label>
      {#if s.settings.correction && !key.maskedKey}
        <p class="row secondary small"><Icon name="info" /> {t('Add a DeepSeek API key below to turn this on.')}</p>
      {/if}
    </div>
    <p class="footer">
      {t("After recognition, DeepSeek V4.1 Flash corrects words the speech service misheard, such as product names, without rewording what you said. It adds about half a second. If DeepSeek doesn't answer within 3 seconds, Kay pastes what it heard.")}
    </p>
  </section>

  <section>
    <h3>{t('DeepSeek API Key')}</h3>
    <form class="card" onsubmit={(e) => (e.preventDefault(), test())}>
      <label class="row">
        <span>{t('API Key')}</span>
        <input type="password" autocomplete="off" bind:value={draft}
          oninput={() => key.candidateError && call('clear_candidate_error', { provider: null })}
          placeholder={key.maskedKey ? t('Saved ({}). Paste a new key to replace it.', key.maskedKey) : t('Paste your DeepSeek API Key')} />
      </label>
      <div class="row start">
        <button class="primary" type="submit" disabled={testing || (!draft.trim() && !key.maskedKey)}>
          {#if testing}<span class="spinner"></span>{:else}{key.maskedKey && !draft.trim() ? t('Test Again') : t('Test & Save')}{/if}
        </button>
        <Status state={key} />
      </div>
    </form>
    <p class="footer links">
      <span>{t('DeepSeek Platform → API Keys. DeepSeek bills you at its standard rates.')}</span>
      <a href={KEYS_URL} onclick={link(KEYS_URL)}>{t('Get an API Key ↗')}</a>
      <a href={CONSOLE_URL} onclick={link(CONSOLE_URL)}>{t('DeepSeek Platform')}</a>
    </p>
    {#if key.maskedKey}
      <button class="danger" onclick={() => (confirmRemove = true)}>{t('Remove Key…')}</button>
    {/if}
  </section>

  <section>
    <h3>{t('Vocabulary')}</h3>
    <div class="card">
      <textarea class="vocabulary" spellcheck="false" bind:value={vocabulary} oninput={() => (failed = false)}></textarea>
      <div class="row">
        {#if failed}
          <span class="message bad"><Icon name="x" /> {t("Couldn't save the vocabulary.")}</span>
        {:else}
          <span class="secondary">{t('{} terms', terms)}</span>
        {/if}
        <span class="buttons">
          <button onclick={() => call('reveal', { file: 'vocabulary' })}>{t('Show in Explorer')}</button>
          <button class="primary" disabled={vocabulary === saved} onclick={save}>{t('Save')}</button>
        </span>
      </div>
    </div>
    <p class="footer">
      {t('Names you spell your own way, one per line. Kay fixes them when they come back spelled out (c f → CF, e to b → E2B). If one is misheard as something else, add that after a bar: Raycast | 瑞卡斯特. # starts a comment.')}
    </p>
  </section>
</div>

<Confirm bind:open={confirmRemove} title={t('Remove this key from Kay?')} action={t('Remove')}
  onconfirm={() => call('remove_correction_key')}>
  {t('It stays valid in DeepSeek. If it was exposed, revoke it on the DeepSeek Platform.')}
</Confirm>
