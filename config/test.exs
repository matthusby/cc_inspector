import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cc_inspector, CcInspectorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4445],
  secret_key_base: "XOtD2hh3+nyKXPorHCmIy95B9Na72DAEw7hFLckdmgCUT6AOMVCDbhTUPD1ZrwJt",
  server: false

# Point session ingest at a tmp dir during tests; tests can override.
config :cc_inspector,
  claude_projects_dir: Path.expand("../tmp/test_claude_projects", __DIR__)

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
