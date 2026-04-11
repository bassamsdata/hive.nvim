# Changelog

## [2.0.0](https://github.com/bassamsdata/hive.nvim/compare/v1.4.0...v2.0.0) (2026-04-11)


### ⚠ BREAKING CHANGES

* add team tool and new plan workflow, and fix the prun context
* rename the plugin to hive.nvim and fix the docs site
* Add core features, refactor and enhancements after many manual testing
* **tools:** add prune tool

### Features

* activate sessions by default ([d9c4fa7](https://github.com/bassamsdata/hive.nvim/commit/d9c4fa7f45fb04c16b63c5286420aa1c06009e0b))
* Add core features, refactor and enhancements after many manual testing ([b338b22](https://github.com/bassamsdata/hive.nvim/commit/b338b22a74dab68fef3e2f776c0e24edc1992139))
* Add prune UI and fix prune tool for openai repsonses mechanism ([1b66bd0](https://github.com/bassamsdata/hive.nvim/commit/1b66bd08eecb515cc4aa904089f1a209bcbc1ecf))
* Add readme and docs ([5ca0557](https://github.com/bassamsdata/hive.nvim/commit/5ca0557e026ad1cdf3092a19a4b5f8eeb77960bb))
* Add session save and restore module ([8cf7aaf](https://github.com/bassamsdata/hive.nvim/commit/8cf7aafbef3f23eded008bb4b13c349af4026229))
* add some other stuff ([b97cbd4](https://github.com/bassamsdata/hive.nvim/commit/b97cbd4622d73ff565b7fc73401330c476757992))
* add team tool and new plan workflow, and fix the prun context ([1fde341](https://github.com/bassamsdata/hive.nvim/commit/1fde3412238ee4bb1a64bc593dae5ff26c8c69ee))
* **Agent_manager:** Add new Agent Manager UI ([6c03157](https://github.com/bassamsdata/hive.nvim/commit/6c03157ce4810dbe94b1c5bd48b4e1a4cf84f780))
* **chat_UI:** when closing parent chat, also close all child chats ([8d4b5fb](https://github.com/bassamsdata/hive.nvim/commit/8d4b5fb2465698a672007100e560dac42a35746b))
* fix the prune tool and add notification for approval request with ([9b902f0](https://github.com/bassamsdata/hive.nvim/commit/9b902f0eb3df621d70357a0816f5749ee1979cfc))
* more robust and useful info for sesions ([3810336](https://github.com/bassamsdata/hive.nvim/commit/3810336f8b00f0d2f1b997902a54caa7dabc1a85))
* rename the plugin to hive.nvim and fix the docs site ([58ca93e](https://github.com/bassamsdata/hive.nvim/commit/58ca93ecd077628e25cc02affb680d997a938c60))
* **todo:** Add split todo window and enhance the module ([631c3cd](https://github.com/bassamsdata/hive.nvim/commit/631c3cdb5275b7c573384f89b814da3d9f5c8dbd))
* **tools:** add prune tool ([bddd1c1](https://github.com/bassamsdata/hive.nvim/commit/bddd1c186885b0a9c9bb5c7b1b03015d3bc50e3e))
* **toolsUX:** send system notification when Neovim loses focus for ask_user tool ([fdaa438](https://github.com/bassamsdata/hive.nvim/commit/fdaa438e95d06648204bb98c78e625916596cf32))
* update .gitignore ([8acf4c8](https://github.com/bassamsdata/hive.nvim/commit/8acf4c8abd17f12efea70f13ea59f0b11953456e))
* update docs and update files headers ([0a69945](https://github.com/bassamsdata/hive.nvim/commit/0a699453b189bf93e1514b8ba58e939b93448646))


### Bug Fixes

* **agents:** remove old reminders when adding new ones ([1ad123a](https://github.com/bassamsdata/hive.nvim/commit/1ad123a5adce82f1086247ab89453a676d9d35cf))
* **consult:** fix icons and highlights in status ([4470e2e](https://github.com/bassamsdata/hive.nvim/commit/4470e2e24741ac0d3647058c1e5df29dc1f54963))
* fix session snapshot ([9a1cc52](https://github.com/bassamsdata/hive.nvim/commit/9a1cc520113f2afe292b266dd6a48093ea4e6f64))
* fix swarm to be more resilient if something happened to agents ([4af965d](https://github.com/bassamsdata/hive.nvim/commit/4af965d3afd0663dc35668c0133330cffde8f96f))
* make default task agent for smaller LLMs ([c18f9bd](https://github.com/bassamsdata/hive.nvim/commit/c18f9bdaea576e2d1a5b3a3ed7cd1debfb64a47f))
* **skills:** fix markdown ([7412586](https://github.com/bassamsdata/hive.nvim/commit/741258642798021b243e7bf7d5bd8737af702ca8))
* **status:** fix highlights ([e468121](https://github.com/bassamsdata/hive.nvim/commit/e4681214417f369b6fa24410375e79d0185fbe8d))
* **todo:** correctly close the split viewer ([0f28593](https://github.com/bassamsdata/hive.nvim/commit/0f285930f460b17d58d37b7e9ba193d23006e868))
* use bun instead ([d01eded](https://github.com/bassamsdata/hive.nvim/commit/d01eded542fef1f904be2d1989e653e85603f30c))

## [1.4.0](https://github.com/bassamsdata/codecompanion-extra.nvim/compare/v1.3.0...v1.4.0) (2026-02-18)


### Features

* **agents:** add cycle agents keymap and some fixes. ([4dae14c](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/4dae14c498466a0df9bf9c9d2c85fa9ac4ca5c29))
* **ask_user:** ability to hide questions UI and restore it back ([a4c66c0](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/a4c66c0595f3466864864685ec2ded031aa0da6b))
* **cmd_runner:** migrate CC cmd_runner and introduce enhancements ([872998b](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/872998bc81fb9dc4b0df1aeb7e1f29992ab9875b))
* **spinner:** Add interaction CMD to the state ([b7f0f1e](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/b7f0f1e5c39cb914d0d50f51fcf668c0491f9644))


### Bug Fixes

* **ask_user:** fix system prompt and highlights ([3f4d7ec](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/3f4d7ec0db4333a53ee4bcaa6725f2ade7062b9e))
* **list_directory:** fix listing outside CWD ([5aae283](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/5aae283c7f9ac9565be21e0434fe8158cb6abf9d))
* **lua_workflow:** delete the file corrupting `lazydev` plugin ([b02ca96](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/b02ca9640d8ff5f3e6fe2e87dc181c7b072b2f6d))
* **tools:** adapt to the new changes in develop ([4ff6433](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/4ff64330a15378a90686ec3b6658a3d7f94c8b45))
* **tools:** fix compatibility layer temporarily since it's still evolving ([9a4c0ee](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/9a4c0ee7248feb8b8318fad71bf56f253124dede))
* **tools:** fix status highlights ([6aa8c7b](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/6aa8c7bfafd492c9da6aa45f5d51248b2a8db178))

## [1.3.0](https://github.com/bassamsdata/codecompanion-extra.nvim/compare/v1.2.0...v1.3.0) (2026-02-12)


### Features

* **agents:** add more agents and enhance prompts ([f55a4cc](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/f55a4cc9d550492ac4f96f9d81d93e9c4bba3b03))
* **agents:** continue refactor agents tool foundation and add consult tool ([af1c2d7](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/af1c2d78dfeb892211e839e0885870f22b6c3123))
* **list_directory:** add hidden option to exclude hidden entries by default ([3a8cfdd](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/3a8cfdd3d2fe0f78ff2d77724dcf4a1ee34af22f))
* **notification:** Add system notification module ([78e6ef6](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/78e6ef6f67d702d5c96a9a0b6db93e5fd42a4b7f))
* **skills:** improve wording to encourage LLM to use skills ([c07b013](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/c07b013a201337eb782f7be9888363b4a19bc0e8))
* **skils:** improve teh wording and system ([08638a3](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/08638a354b8a09563c3444586bee11c8030d852d))
* **state:** Add inline state ([792d8dc](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/792d8dc5d565e8d937f5c2c13730afd2e80864e1))
* **state:** refactor spinner and add state‑management foundation ([5c14978](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/5c1497803a888edebde29334fa353b92f281e456))
* **task:** convert the module to OOP for better state handling ([c3aedad](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/c3aedadcacde70826f7f545ec8f95c0c17700416))
* **todo:** Add new todo tool for task management ([c1b6f44](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/c1b6f44f80787e5b27a09e36025ad76bead943ae))
* **todo:** Add viewer and enhance the todo tool functionality ([baacbe5](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/baacbe564e17cb55ff5be6a34a74f82fe02ad6d9))
* **todo:** integrate todo in the system ([77a4121](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/77a4121f8cae7c9cd6a9baa41ae4c61907688fe5))
* **tools:** Adapt to the new Codeocmpanion API chnages ([57c7178](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/57c717864784e1e7263e6d1332c11fc8582e79e9))
* **tools:** add compat module for compatibility with new and old API ([c74950a](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/c74950a919e865b7c717273c44e398425c7566a8))
* **tools:** expose consult and cleanup todo tools after chat closed ([b82c34e](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/b82c34e8bf7aaae3b3a5041e6ab4f5e770c36bed))
* **UI:** add system notification for MacOS and Linux ([98e75a0](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/98e75a0e878fba2d90c1ace63dc7c71546888dec))
* **UI:** add the config option for scroll ([6cefc3b](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/6cefc3b1eba4977ddc724b63c2de69ae337d30e6))
* **UI:** center the buffer when agent tools start showing status. ([5264e86](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/5264e8625d07956b7db73b86bb3c354e53285998))
* **workflow:** adding workflow for test codeocmpanion internal API ([018346d](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/018346d40184dca3ca5c5f39e18349574ef37c86))


### Bug Fixes

* **agents:** properly update the agent session name- fix winbar ([7b2b153](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/7b2b15326a6bf4e5a20385779a72cef2ff0d61a5))
* **ask_user:** fix how the context window appears ([65dec03](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/65dec03f4b16f4d61accbfb529e6a8763d219983))
* **docs:** fix help message ([02178eb](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/02178ebe9ac3b24abede5e7b05333793ec650b64))
* **state:** wip ([3ca9620](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/3ca9620c17fdb0bee8579f70b07e4b46647b7e26))
* **state:** wip - fixing state with tool gaps for confirm() fn ([0c88f97](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/0c88f97e8c72de5e3bf581434ca59ff2fc075d18))
* **task:** fix the naming of LLM role ([b4ae481](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/b4ae48168d962393ba4ec9155876378a05e7db2c))

## [1.2.0](https://github.com/bassamsdata/codecompanion-extra.nvim/compare/v1.1.0...v1.2.0) (2026-01-30)


### Features

* add task tool to orchestrate the sub-agent system ([b393ddc](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/b393ddcb6aca53032e6fc314d1f5bc65165973d2))
* **agents:** move from modes to agents-subagents system ([984eedc](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/984eedcb2ab64b2f3483ae004d5d5d494f0e7aed))
* **ask_user:** add ask_user tool for interactions questions from LLM ([692827c](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/692827c1545ffe8ab739425ca6793e23cd09524e))
* **config:** add config file ([99d0f78](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/99d0f78e9518ab75158815d66df6eae93f3711b1))
* **list_directory:** add tool to list directory contents ([0153815](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/0153815e824d192f243545a2467777091ff3f022))
* **mode:** Add 2 builtin autonomous agents and way to extend ([0de82ad](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/0de82adc4c31ca968251ce349a346632b460d175))
* **plugin:** Add main plugin file to be loaded via commands ([413737c](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/413737ca276944a6ea01cb3bac7e53c9ca94d4b3))
* **skills:** add new neovim tag help skill ([375faf0](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/375faf026a41c96b241a5393376c468af5898768))
* **skills:** add skills mechanism and tool for agentskills.io method ([514c773](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/514c773e521b67ce00e4fffd49e40498cc43c3a9))
* **task:** enahnce the task tool massively ([c20cd5f](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/c20cd5f7fc078c236c305bedb99c6b551f995efc))

## [1.1.0](https://github.com/bassamsdata/codecompanion-extra.nvim/compare/v1.0.0...v1.1.0) (2026-01-14)


### Features

* **adaptes:** move my adapters to the plugin from my config ([004650d](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/004650dd4fc811b677a64f59b6a36fab5d34888f))

## 1.0.0 (2026-01-13)


### Features

* **core:** add the main init file ([2d17a52](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/2d17a52bcc23b7c28ef5e051767c5d70e37ebc20))
* **initial:** extract spinner from config to dedicated plugin ([34862bc](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/34862bc030cd3abd627111939181c1d46f0ef62a))
* **tools:** move main module and get_diagnostic tool from my config ([cde7f8f](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/cde7f8fc6ea620aaae2f2a5fa9a1385ec5c2a130))
* **workflow:** Add stylua code config file ([8d11347](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/8d1134705a4d5f3b99217d5adf03a44382734ffd))
* **workflows:** adding github release workflow and makefile ([01935fb](https://github.com/bassamsdata/codecompanion-extra.nvim/commit/01935fb0da0a8c29e5153f7f0ea9e7960b0952e0))
