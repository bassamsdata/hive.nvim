import { defineConfig } from "vitepress";

export default defineConfig({
  title: "Hive",
  description:
    "Multi-agent orchestration for Neovim, built on Codecompanion.nvim",
  base: "/hive.nvim/",

  head: [["link", { rel: "icon", href: "/hive.nvim/favicon.ico" }]],

  themeConfig: {
    logo: "/logo.svg",

    nav: [
      { text: "Guide", link: "/guide/getting-started" },
      { text: "Reference", link: "/reference/config" },
    ],

    sidebar: {
      "/guide/": [
        {
          text: "Introduction",
          items: [
            { text: "What is Hive?", link: "/guide/what-is-hive" },
            { text: "Getting Started", link: "/guide/getting-started" },
          ],
        },
        {
          text: "Core Concepts",
          items: [
            { text: "Agents", link: "/guide/agents" },
            { text: "Tools", link: "/guide/tools" },
            { text: "Context Lifecycle", link: "/guide/context-lifecycle" },
            { text: "Subagents", link: "/guide/subagents" },
          ],
        },
        {
          text: "Advanced",
          items: [
            { text: "Custom Agents", link: "/guide/custom-agents" },
            { text: "Swarm Orchestration", link: "/guide/swarm" },
          ],
        },
      ],
      "/reference/": [
        {
          text: "Reference",
          items: [
            { text: "Configuration", link: "/reference/config" },
            { text: "Keymaps", link: "/reference/keymaps" },
            { text: "Commands", link: "/reference/commands" },
          ],
        },
      ],
    },

    socialLinks: [
      { icon: "github", link: "https://github.com/bassamsdata/hive.nvim" },
    ],

    search: {
      provider: "local",
    },

    editLink: {
      pattern:
        "https://github.com/bassamsdata/hive.nvim/edit/main/docs/:path",
    },
  },
});
