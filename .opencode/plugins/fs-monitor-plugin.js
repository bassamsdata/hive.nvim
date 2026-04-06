process.env.NVIM_LISTEN_ADDRESS = process.env.NVIM_LISTEN_ADDRESS || "/var/folders/d8/__x1yn897wd5s6wz_5l04jxh0000gn/T/nvim.bassam/VvPuA8/nvim.56526.0";
// fs-monitor-opencode-plugin.js
// OpenCode plugin for fs-monitor.nvim
// Logs to /tmp/fs-monitor-opencode.log for debugging.
//
// Strategy (mirrors Claude adapter):
//   tool.execute.before → activate FS watcher (catches mv, sed, etc.)
//   tool.execute.after  → deactivate watcher + register specific file
//   session.idle        → checkpoint + incremental baseline refresh

import { appendFileSync, readdirSync, statSync } from "fs";
import { join } from "path";

const LOG = "/tmp/fs-monitor-opencode.log";

function log(msg) {
    try {
        const ts = new Date().toTimeString().slice(0, 8);
        appendFileSync(LOG, `[${ts}] ${msg}\n`);
    } catch {
        // ignore
    }
}

/** Collect all Neovim server sockets on macOS/Linux */
function findAllNvimSockets() {
    const sockets = [];
    const addr = process.env.NVIM_LISTEN_ADDRESS;
    if (addr) return [addr];

    // macOS: sockets in $TMPDIR/nvim.*/*/nvim.*.0
    const tmpdir = process.env.TMPDIR || "/tmp";
    try {
        const nvimDirs = readdirSync(tmpdir).filter((d) => d.startsWith("nvim."));
        for (const nvimDir of nvimDirs) {
            const nvimPath = join(tmpdir, nvimDir);
            try {
                for (const sub of readdirSync(nvimPath)) {
                    const subPath = join(nvimPath, sub);
                    try {
                        for (const f of readdirSync(subPath)) {
                            if (f.startsWith("nvim.") && f.endsWith(".0")) {
                                sockets.push(join(subPath, f));
                            }
                        }
                    } catch { }
                }
            } catch { }
        }
    } catch { }

    // Linux fallback
    try {
        for (const d of readdirSync("/tmp").filter((d) => d.startsWith("nvim."))) {
            const sock = join("/tmp", d, "0");
            try {
                statSync(sock);
                sockets.push(sock);
            } catch { }
        }
    } catch { }

    return sockets;
}

export const FSMonitorPlugin = async ({ $, directory }) => {
    log(`=== Plugin loaded ===`);
    log(`directory: ${directory}`);

    const sockets = findAllNvimSockets();
    log(`Found ${sockets.length} socket(s): ${sockets.join(", ")}`);

    /** Try RPC on all sockets until one works */
    async function rpc(expr) {
        if (sockets.length === 0) {
            const retry = findAllNvimSockets();
            if (retry.length === 0) {
                log(`RPC SKIP: no sockets found`);
                return;
            }
            sockets.push(...retry);
        }

        for (const sock of sockets) {
            try {
                const result =
                    await $`nvim --server ${sock} --remote-expr ${expr}`.text();
                log(`RPC OK (${sock}): ${result.trim()}`);
                return;
            } catch {
                // This socket is dead, try next
            }
        }
        log(`RPC FAIL: all ${sockets.length} sockets refused connection`);
    }

    function escapeLua(s) {
        return s.replace(/'/g, "\\'");
    }

    return {
        event: async ({ event }) => {
            if (event.type === "file.edited") {
                const filePath =
                    event.properties?.file ||
                    event.properties?.path ||
                    event.properties?.filePath ||
                    "";
                log(`file.edited: path="${filePath}"`);
                if (filePath) {
                    const escaped = escapeLua(filePath);
                    await rpc(
                        `v:lua.require('fs-monitor.providers.opencode')._on_file_changed('${escaped}')`,
                    );
                }
            } else if (event.type === "session.idle") {
                log(`session.idle`);
                await rpc(
                    "v:lua.require('fs-monitor.providers.opencode')._on_session_complete()",
                );
            }
        },

        // Before ANY tool: activate the FS watcher
        "tool.execute.before": async (input, _output) => {
            const tool = input.tool || "unknown";
            log(`tool.execute.before: tool="${tool}"`);
            const escaped = escapeLua(tool);
            await rpc(
                `v:lua.require('fs-monitor.providers.opencode')._on_pre_tool_use('${escaped}')`,
            );
        },

        // After ANY tool: deactivate watcher + register file for WRITE tools only
        "tool.execute.after": async (input, _output) => {
            const tool = input.tool || "unknown";
            const WRITE_TOOLS = new Set([
                "write",
                "edit",
                "patch",
                "multi_edit",
                "multiedit",
            ]);

            // Only extract file_path for tools that modify files
            // read/list/glob/search etc. have file_path but don't change anything
            const filePath = WRITE_TOOLS.has(tool)
                ? input.args?.file_path ||
                input.args?.filePath ||
                input.args?.path ||
                ""
                : "";

            log(
                `tool.execute.after: tool="${tool}" file="${filePath || "<none>"}"`,
            );

            const toolEscaped = escapeLua(tool);
            if (filePath) {
                const fileEscaped = escapeLua(filePath);
                await rpc(
                    `v:lua.require('fs-monitor.providers.opencode')._on_post_tool_use('${fileEscaped}','${toolEscaped}')`,
                );
            } else {
                // For bash, read, etc. — just deactivate watcher, no file registration
                await rpc(
                    `v:lua.require('fs-monitor.providers.opencode')._on_post_tool_use('','${toolEscaped}')`,
                );
            }
        },
    };
};
