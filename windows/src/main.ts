import { mount } from 'svelte';
import App from './App.svelte';
import { connect } from './kay.svelte';
import './app.css';

await connect();
mount(App, { target: document.body });
