// Runbranch — run any branch of any project on a real port.
// Copyright (C) 2026 Alec McLeod
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; without even the
// implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details:
// <https://www.gnu.org/licenses/>.

// The harness's demo data: plausible projects under C:\Code, so a capture
// shows what a sheet looks like in use and publishes nothing real.

namespace Runbranch.Dialogs;

public static partial class Harness
{
    static class Demo
    {
        public const string RunScript = """
            $lines = @(
              '==> Checking out feat/checkout-summary into a worktree',
              '    ~\.runbranch\worktrees\northwind\feat-checkout-summary-2094412',
              '==> Copying .env.local',
              '==> Installing: pnpm install --frozen-lockfile',
              'Lockfile is up to date, resolution step is skipped',
              'Packages: +812',
              'Progress: resolved 812, reused 812, downloaded 0, added 812, done',
              'dependencies:',
              '+ @northwind/ui 4.2.0',
              '+ vite 7.1.3',
              'Done in 6.4s',
              '==> Starting web on port 5173',
              '==> Waiting for http://localhost:5173/ to answer')
            foreach ($l in $lines) { [Console]::Out.WriteLine($l); [Console]::Out.Flush(); Start-Sleep -Milliseconds 120 }
            Start-Sleep -Seconds 120
            """;

        public static readonly IReadOnlyList<RunTarget> Targets =
            [new("web", 5173, "/", 41822, true), new("api", 8080, "/health", 41830, true)];

        /// <summary>A log folder with a tail worth reading, written fresh each time.</summary>
        public static string LogDir()
        {
            var dir = Path.Combine(Path.GetTempPath(), "runbranch-harness-logs");
            Directory.CreateDirectory(dir);
            File.WriteAllLines(Path.Combine(dir, "web.log"),
            [
                "\u001b[32m  VITE v7.1.3\u001b[0m  ready in 412 ms",
                "  ➜  Local:   http://localhost:5173/",
                "  ➜  Network: use --host to expose",
                "12:04:11 [vite] hmr update /src/checkout/Summary.tsx",
                "12:04:18 [vite] hmr update /src/checkout/Summary.tsx, /src/checkout/Totals.tsx",
                "12:05:02 [vite] Internal server error: Failed to resolve import \"./Discount\" from \"src/checkout/Totals.tsx\"",
                "  Plugin: vite:import-analysis",
                "  File: src/checkout/Totals.tsx:4:22",
                "12:05:09 [vite] hmr update /src/checkout/Discount.tsx",
                "12:05:09 [vite] page reload src/checkout/Totals.tsx",
                "12:06:40 GET /api/cart 200 18ms",
                "12:06:41 GET /api/cart/totals 200 22ms",
                "12:06:52 POST /api/cart/items 201 41ms",
                "12:07:03 Error: connect ECONNREFUSED 127.0.0.1:8080 (proxy /api/stock)",
                "12:07:05 GET /api/cart 200 16ms",
            ]);
            File.WriteAllLines(Path.Combine(dir, "api.log"),
            [
                "INFO  listening on :8080",
                "INFO  GET /health 200 1ms",
                "WARN  slow query: 412ms select * from carts where id = $1",
                "INFO  GET /cart 200 9ms",
            ]);
            return dir;
        }

        public static List<PortRow> Ports =>
        [
            new("northwind", "web", 5173, "ours", "northwind", 41822, "node C:\\Code\\northwind-web\\node_modules\\vite\\bin\\vite.js --port 5173"),
            new("northwind", "api", 8080, "ours", "northwind", 41830, "node dist\\server.js"),
            new("ledger", "web", 3000, "free", "", 0, ""),
            new("ledger", "worker", 3001, "free", "", 0, ""),
            new("atlas", "docs", 4000, "outside", "atlas", 9120, "python -m http.server 4000"),
            new("atlas", "app", 3000, "free", "", 0, ""),
            new("pantry", "web", 5174, "outside", "", 7712, "C:\\Program Files\\Docker\\Docker\\resources\\com.docker.backend.exe"),
        ];

        public static List<PortOverlap> Overlaps => [new(3000, ["ledger", "atlas"])];

        public static PendingRun Pending(bool outside) => new("northwind", "feat/checkout-summary", "web", "Starting feat/checkout-summary", false,
            outside
                ? new PortConflict([new("web", 5173, "northwind", PortClash.Kinds.Outside, 51220, PortClash.Moves.Env)], 1)
                : new PortConflict(
                [
                    new("web", 5173, "ledger", PortClash.Kinds.Ours, 41822, PortClash.Moves.Explicit),
                    new("api", 8080, "", PortClash.Kinds.Unknown, 7712, PortClash.Moves.Env),
                ], 10));

        public static List<DiskRow> Disk =>
        [
            new("northwind", "feat-checkout-summary-2094412", "feat/checkout-summary", 412_880, "running"),
            new("northwind", "fix-tax-rounding-11028", "fix/tax-rounding", 398_112, "idle"),
            new("northwind", "spike-edge-cache-88121", "spike/edge-cache", 401_004, "gone"),
            new("ledger", "main-661", "main", 88_310, "idle"),
            new("atlas", "docs-refresh-1203", "?", 12_040, "gone"),
        ];

        public static List<ScanResult> Found =>
        [
            new("northwind-web", @"C:\Code\northwind-web"),
            new("ledger", @"C:\Code\ledger"),
            new("atlas", @"C:\Code\clients\atlas"),
            new("pantry", @"C:\Code\side\pantry"),
        ];

        public static Dictionary<string, string> Config => new()
        {
            ["NAME"] = "Northwind Web",
            ["SYMBOL"] = "cart",
            ["DEFAULT_BRANCH"] = "main",
            ["REPO"] = @"C:\Code\northwind-web",
            ["TARGETS"] = "web:5173:/:pnpm dev --port {port}\napi:8080:/health:pnpm --filter api start",
            ["ALWAYS"] = "api",
            ["PRESETS"] = "web=web  both=web,api",
            ["PORT_OFFSET"] = "1",
            ["PROCFILE"] = "0",
            ["OPENS_ITSELF"] = "0",
            ["INSTALL"] = "pnpm install --frozen-lockfile",
            ["RUNTIME"] = "fnm",
            ["COPY_FILES"] = ".env.local",
            ["COMPOSE_SERVICES"] = "postgres valkey",
            ["COMPOSE_PROJECT"] = "",
            ["MIGRATE"] = "pnpm db:migrate",
            ["SEED"] = "",
            ["DB_URL_VARS"] = "DATABASE_URL",
            ["IN_REPO"] = @"C:\Code\northwind-web\.runbranch",
        };

        public const string Notes = """
            **Two projects that want the same port**

            The Ports sheet now lists every port more than one project declares, and
            *Move…* gives one of them a `PORT_OFFSET` that clears all of its ports at once.

            - Offsets keep a project's ports together, so 3000 and 3001 stay adjacent
            - `{port}` in a command is rewritten to match
            - The editor says where each port ends up
            """;
    }
}
