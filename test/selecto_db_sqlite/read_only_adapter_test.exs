defmodule SelectoDBSQLite.ReadOnlyAdapterTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter

  test "does not advertise or implement portable writes" do
    for feature <- [:insert, :update, :upsert, :delete, :returning] do
      refute Adapter.supports?(feature)
    end

    refute function_exported?(Adapter, :write_capabilities, 1)
    refute function_exported?(Adapter, :preview_write, 3)
    refute function_exported?(Adapter, :execute_write, 3)
  end
end
