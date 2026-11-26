<script lang="ts" module>
  // Line icons on a 24-unit grid, drawn for Kay. One stroke style everywhere.
  const paths = {
    dictations: 'M5 5h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-7l-4 3v-3H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2zM8 10h8M8 13h5',
    general: 'M4 7h10M18 7h2M4 17h4M12 17h8M14 4.5v5M8 14.5v5',
    speech: 'M5 10v4M9 7v10M13 4v16M17 8v8M21 11v2',
    correction: 'M4 7h11M4 12h7M4 17h6M13 16l3 3 5-6',
    mic: 'M12 3a3 3 0 0 1 3 3v6a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3zM6 11a6 6 0 0 0 12 0M12 17v4M9 21h6',
    'mic-off': 'M15 9V6a3 3 0 0 0-5.7-1.3M9 9v3a3 3 0 0 0 4.6 2.5M6 11a6 6 0 0 0 9.5 4.9M18 11a6 6 0 0 1-.4 2.1M12 17v4M9 21h6M4 4l16 16',
    key: 'M8 15a4 4 0 1 1 0-8 4 4 0 0 1 0 8zM12 11h9M18 11v3M21 11v2',
    check: 'M5 12.5l4.5 4.5L19 7.5',
    'check-circle': 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM8 12.5l3 3 5-6',
    copy: 'M9 9h10v11H9zM15 9V5H5v11h4',
    trash: 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6',
    search: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM15.5 15.5L20 20',
    info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v6M12 7.5v.5',
    warning: 'M12 4l9 16H3zM12 10v4M12 17v.5',
    ear: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6M12 17v.5',
    clipboard: 'M8 5H6v16h12V5h-2M9 3h6v4H9z',
    recover: 'M4 12a8 8 0 1 0 2.3-5.7M4 4v4h4',
    minus: 'M8 12h8M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z',
    x: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM9 9l6 6M15 9l-6 6',
  } as const;
  export type IconName = keyof typeof paths;
</script>

<script lang="ts">
  let { name, size = 16 }: { name: IconName; size?: number } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
  stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={paths[name]} /></svg>
