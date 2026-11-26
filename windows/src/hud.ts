import { mount } from 'svelte';
import Hud from './Hud.svelte';
import { loadLanguage } from './kay.svelte';
import './hud.css';

await loadLanguage();
mount(Hud, { target: document.body });
