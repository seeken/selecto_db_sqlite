defmodule SelectoDBSQLite.UpdatoAdapter do
  @moduledoc false

  @behaviour SelectoUpdato.WriteAdapter

  defdelegate name(), to: SelectoUpdato.WriteAdapters.SQLite
  defdelegate validate_operation(op), to: SelectoUpdato.WriteAdapters.SQLite

  defdelegate merge_upsert_opts(op, conflict_opts, on_conflict_opts, base_opts),
    to: SelectoUpdato.WriteAdapters.SQLite

  defdelegate maybe_load_upsert_result(record, op, repo), to: SelectoUpdato.WriteAdapters.SQLite
  defdelegate upsert_preview_style(), to: SelectoUpdato.WriteAdapters.SQLite
end
