defmodule Selecto.DB.SQLite do
  @moduledoc """
  SQLite adapter for Selecto.
  
  This adapter provides SQLite support for the Selecto query builder.
  It handles SQLite-specific SQL syntax, type conversions, and limitations.
  
  ## Installation
  
  Add `selecto_db_sqlite` to your dependencies:
  
      def deps do
        [
          {:selecto, "~> 1.0"},
          {:selecto_db_sqlite, "~> 0.1"},
          {:exqlite, "~> 0.13"}
        ]
      end
  
  ## Usage
  
      # Configure with SQLite file
      selecto = Selecto.configure(
        domain,
        [database: "path/to/database.db"],
        adapter: Selecto.DB.SQLite
      )
      
      # Or use in-memory database
      selecto = Selecto.configure(
        domain,
        [database: ":memory:"],
        adapter: Selecto.DB.SQLite
      )
      
      # Execute queries
      {:ok, results} = Selecto.execute(selecto)
  
  ## Supported Features
  
  - Basic CRUD operations
  - Joins (INNER, LEFT, CROSS)
  - CTEs and recursive CTEs
  - Window functions (SQLite 3.25+)
  - JSON operations (JSON1 extension)
  - Full-text search (FTS5 extension)
  - Transactions with savepoints
  - In-memory databases
  - Attached databases
  
  ## Limitations
  
  - No RIGHT JOIN or FULL OUTER JOIN (can be emulated)
  - Limited ALTER TABLE support
  - No stored procedures
  - Dynamic typing (type affinity)
  - No native UUID type (store as TEXT)
  - Single writer at a time
  """

  use Selecto.Database.Adapter
  
  alias Selecto.Database.Types

  @behaviour Selecto.Database.Adapter

  # Connection Management
  
  @impl true
  def connect(opts) do
    database = Keyword.get(opts, :database, ":memory:")
    
    # Exqlite connection options
    sqlite_opts = [
      database: database,
      journal_mode: Keyword.get(opts, :journal_mode, :wal),
      cache_size: Keyword.get(opts, :cache_size, -2000),
      foreign_keys: Keyword.get(opts, :foreign_keys, :on),
      busy_timeout: Keyword.get(opts, :busy_timeout, 2000)
    ]
    
    case Exqlite.Sqlite3.open(database) do
      {:ok, conn} ->
        # Configure SQLite settings
        configure_connection(conn, sqlite_opts)
        {:ok, conn}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def disconnect(conn) do
    Exqlite.Sqlite3.close(conn)
    :ok
  end

  @impl true
  def checkout(pool) do
    # For SQLite, we'll use the same connection
    {:ok, pool}
  end

  @impl true
  def checkin(_pool, _conn) do
    :ok
  end

  # Query Execution

  @impl true
  def execute(conn, query, params, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    
    # Convert numbered parameters to SQLite format
    sqlite_query = convert_parameters(query, params)
    
    with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sqlite_query),
         :ok <- bind_parameters(statement, params),
         {:ok, columns} <- Exqlite.Sqlite3.columns(conn, statement),
         {:ok, rows} <- fetch_all(conn, statement, timeout) do
      
      columns = columns || []
      num_rows = length(rows)
      
      {:ok, %{
        columns: columns,
        rows: rows,
        num_rows: num_rows,
        metadata: %{}
      }}
    else
      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @impl true
  def prepare(conn, name, query) do
    sqlite_query = convert_parameters(query, [])
    
    case Exqlite.Sqlite3.prepare(conn, sqlite_query) do
      {:ok, statement} -> 
        # Store the statement with a name for later use
        {:ok, {name, statement}}
      {:error, reason} -> 
        {:error, reason}
    end
  end

  @impl true
  def execute_prepared(conn, {_name, statement}, params, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    
    with :ok <- Exqlite.Sqlite3.reset(statement),
         :ok <- bind_parameters(statement, params),
         {:ok, columns} <- Exqlite.Sqlite3.columns(conn, statement),
         {:ok, rows} <- fetch_all(conn, statement, timeout) do
      
      columns = columns || []
      num_rows = length(rows)
      
      {:ok, %{
        columns: columns,
        rows: rows,
        num_rows: num_rows,
        metadata: %{}
      }}
    else
      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # Transaction Management

  @impl true
  def transaction(conn, fun, _opts) do
    case execute(conn, "BEGIN", [], []) do
      {:ok, _} ->
        try do
          result = fun.(conn)
          case execute(conn, "COMMIT", [], []) do
            {:ok, _} -> {:ok, result}
            error -> 
              execute(conn, "ROLLBACK", [], [])
              error
          end
        rescue
          exception ->
            execute(conn, "ROLLBACK", [], [])
            reraise exception, __STACKTRACE__
        end
      
      error -> 
        error
    end
  end

  @impl true
  def begin(conn, opts) do
    mode = case Keyword.get(opts, :mode, :deferred) do
      :deferred -> "DEFERRED"
      :immediate -> "IMMEDIATE"
      :exclusive -> "EXCLUSIVE"
      _ -> "DEFERRED"
    end
    
    query = "BEGIN #{mode}"
    
    case execute(conn, query, [], []) do
      {:ok, _} -> {:ok, conn}
      error -> error
    end
  end

  @impl true
  def commit(conn) do
    case execute(conn, "COMMIT", [], []) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def rollback(conn) do
    case execute(conn, "ROLLBACK", [], []) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def savepoint(conn, name) do
    case execute(conn, "SAVEPOINT #{name}", [], []) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def rollback_to_savepoint(conn, name) do
    case execute(conn, "ROLLBACK TO SAVEPOINT #{name}", [], []) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # SQL Dialect

  @impl true
  def quote_identifier(identifier) do
    "\"#{String.replace(identifier, "\"", "\"\"")}\"" 
  end

  @impl true
  def quote_string(string) do
    "'#{String.replace(string, "'", "''")}'"
  end

  @impl true
  def parameter_placeholder(_index) do
    "?"
  end

  @impl true
  def limit_syntax do
    :limit_offset
  end

  @impl true
  def boolean_literal(true), do: "1"
  def boolean_literal(false), do: "0"

  # Feature Capabilities

  @impl true
  def supports?(feature) do
    feature in supported_features() or version_dependent_feature?(feature)
  end

  @impl true
  def capabilities do
    # Start with all supported features = true
    base_capabilities = supported_features()
      |> Enum.map(&{&1, true})
      |> Map.new()
    
    # Add explicitly unsupported features = false
    unsupported_features = %{
      right_join: false,
      full_outer_join: false, 
      lateral_join: false,
      arrays: false,
      uuid: false,
      two_phase_commit: false,
      stored_procedures: false,
      explain_analyze: false
    }
    
    # Add version-dependent features with detailed info
    version_features = %{
      window_functions: {:version, "3.25", version_compare(version(), "3.25") >= 0},
      upsert: {:version, "3.24", version_compare(version(), "3.24") >= 0},
      generated_columns: {:version, "3.31", version_compare(version(), "3.31") >= 0}
    }
    
    # Add adapter metadata
    metadata = %{
      version: version(),
      dialect: "sqlite",
      max_identifier_length: 255,
      max_query_length: 1_000_000
    }
    
    base_capabilities
    |> Map.merge(unsupported_features)
    |> Map.merge(version_features)
    |> Map.merge(metadata)
  end

  defp supported_features do
    [
      # Core SQL features (required)
      :select, :insert, :update, :delete, :where, :joins, :subqueries, :group_by, :order_by,
      
      # Join types (SQLite supported only)
      :inner_join, :left_join, :cross_join,
      
      # Advanced SQL
      :cte, :recursive_cte, :returning,
      
      # Data types
      :json, :regex,
      
      # Text search
      :fulltext_search,
      
      # Transactions
      :savepoints,
      
      # Constraints & Indexes
      :check_constraints, :partial_indexes, :expression_indexes,
      
      # Performance
      :explain,
      
      # SQLite specific features
      :in_memory, :attach_database, :triggers, :views, :indexes
    ]
  end

  @impl true
  def version do
    # This would normally query sqlite_version()
    "3.40.0"
  end

  # Type System

  @impl true
  def encode_type(value, type) do
    case {type, value} do
      {:boolean, true} -> 1
      {:boolean, false} -> 0
      
      {:json, value} when is_map(value) or is_list(value) ->
        Jason.encode!(value)
      
      {:array, value} when is_list(value) ->
        # Use JSON for arrays in SQLite
        Jason.encode!(value)
      
      {:datetime, %DateTime{} = value} ->
        DateTime.to_iso8601(value)
      
      {:naive_datetime, %NaiveDateTime{} = value} ->
        NaiveDateTime.to_iso8601(value)
      
      {:date, %Date{} = value} ->
        Date.to_iso8601(value)
      
      {:time, %Time{} = value} ->
        Time.to_iso8601(value)
      
      {:decimal, %Decimal{} = value} ->
        Decimal.to_string(value)
      
      _ ->
        value
    end
  end

  @impl true
  def decode_type(value, type) do
    case type do
      :boolean ->
        case value do
          1 -> true
          0 -> false
          "1" -> true
          "0" -> false
          "true" -> true
          "false" -> false
          _ -> value
        end
      
      :json when is_binary(value) ->
        Jason.decode!(value)
      
      :array when is_binary(value) ->
        Jason.decode!(value)
      
      :datetime when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> dt
          _ -> value
        end
      
      :naive_datetime when is_binary(value) ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> ndt
          _ -> value
        end
      
      :date when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _ -> value
        end
      
      :time when is_binary(value) ->
        case Time.from_iso8601(value) do
          {:ok, time} -> time
          _ -> value
        end
      
      :decimal when is_binary(value) ->
        Decimal.new(value)
      
      :integer when is_binary(value) ->
        String.to_integer(value)
      
      :float when is_binary(value) ->
        String.to_float(value)
      
      _ ->
        value
    end
  end

  @impl true
  def type_name(elixir_type) do
    case elixir_type do
      :string -> "TEXT"
      :text -> "TEXT"
      :integer -> "INTEGER"
      :bigint -> "INTEGER"
      :float -> "REAL"
      :decimal -> "NUMERIC"
      :boolean -> "INTEGER"
      :date -> "TEXT"
      :time -> "TEXT"
      :datetime -> "TEXT"
      :naive_datetime -> "TEXT"
      :utc_datetime -> "TEXT"
      :binary -> "BLOB"
      :uuid -> "TEXT"
      :json -> "TEXT"
      :array -> "TEXT"
      _ -> "TEXT"
    end
  end

  # Introspection

  @impl true
  def list_tables(conn, _opts) do
    query = """
    SELECT name 
    FROM sqlite_master 
    WHERE type = 'table' 
    AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """
    
    case execute(conn, query, [], []) do
      {:ok, %{rows: rows}} ->
        tables = Enum.map(rows, fn [table] -> table end)
        {:ok, tables}
      error ->
        error
    end
  end

  @impl true
  def table_exists?(conn, table, _opts) do
    query = """
    SELECT EXISTS (
      SELECT 1 
      FROM sqlite_master 
      WHERE type = 'table' AND name = ?
    )
    """
    
    case execute(conn, query, [table], []) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: [[0]]}} -> false
      _ -> false
    end
  end

  @impl true
  def describe_table(conn, table, _opts) do
    # Use PRAGMA table_info to get column information
    query = "PRAGMA table_info(#{quote_identifier(table)})"
    
    case execute(conn, query, [], []) do
      {:ok, %{rows: rows}} ->
        columns = Enum.map(rows, fn [_cid, name, type, notnull, default, pk] ->
          %{
            name: name,
            type: type,
            nullable: notnull == 0,
            default: default,
            primary_key: pk == 1
          }
        end)
        
        {:ok, %{
          table: table,
          columns: columns
        }}
      
      error ->
        error
    end
  end

  # Performance & Optimization

  @impl true
  def explain(conn, query, opts) do
    query_plan = Keyword.get(opts, :query_plan, false)
    
    explain_query = if query_plan do
      "EXPLAIN QUERY PLAN #{query}"
    else
      "EXPLAIN #{query}"
    end
    
    case execute(conn, explain_query, [], []) do
      {:ok, %{rows: rows, columns: columns}} ->
        if query_plan do
          # Format query plan output
          plan = Enum.map(rows, fn row ->
            Enum.zip(columns, row) |> Map.new()
          end)
          {:ok, plan}
        else
          # Bytecode output
          {:ok, rows}
        end
      
      error ->
        error
    end
  end

  @impl true
  def analyze(conn, table, _opts) do
    case execute(conn, "ANALYZE #{quote_identifier(table)}", [], []) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Streaming Support

  @impl true
  def stream(_conn, _query, _params, _opts) do
    # SQLite doesn't have native streaming like PostgreSQL
    # Could implement cursor-like behavior with LIMIT/OFFSET
    {:error, :not_implemented}
  end

  # Private Functions

  defp supported_features do
    [
      # Basic features
      :select, :insert, :update, :delete, :where, :joins, :subqueries, 
      :group_by, :order_by,
      
      # Join types  
      :inner_join, :left_join, :cross_join,
      
      # Advanced SQL
      :cte, :recursive_cte, :returning,
      
      # Data types (with extensions)
      :json,
      
      # Text search (with FTS5)
      :fulltext_search, :regex,
      
      # Transactions
      :savepoints,
      
      # SQLite specific
      :in_memory, :attach_database,
      
      # Other
      :explain, :triggers, :views, :indexes
    ]
  end

  defp version_dependent_feature?(feature) do
    case feature do
      :window_functions -> version_compare(version(), "3.25") >= 0
      :upsert -> version_compare(version(), "3.24") >= 0
      :generated_columns -> version_compare(version(), "3.31") >= 0
      _ -> false
    end
  end

  defp configure_connection(conn, opts) do
    # Set journal mode
    if journal_mode = opts[:journal_mode] do
      Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = #{journal_mode}")
    end
    
    # Set cache size
    if cache_size = opts[:cache_size] do
      Exqlite.Sqlite3.execute(conn, "PRAGMA cache_size = #{cache_size}")
    end
    
    # Enable foreign keys
    if opts[:foreign_keys] == :on do
      Exqlite.Sqlite3.execute(conn, "PRAGMA foreign_keys = ON")
    end
    
    # Set busy timeout
    if busy_timeout = opts[:busy_timeout] do
      Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = #{busy_timeout}")
    end
    
    # Load extensions if specified
    if extensions = opts[:extensions] do
      Enum.each(extensions, fn ext ->
        Exqlite.Sqlite3.enable_load_extension(conn, true)
        Exqlite.Sqlite3.execute(conn, "SELECT load_extension('#{ext}')")
      end)
    end
  end

  defp bind_parameters(statement, params) do
    # Bind all parameters at once using the correct API
    case Exqlite.Sqlite3.bind(statement, params) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_all(db, statement, timeout) do
    # Fetch all rows with timeout
    task = Task.async(fn ->
      fetch_rows(db, statement, [])
    end)
    
    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp fetch_rows(db, statement, acc) do
    case Exqlite.Sqlite3.step(db, statement) do
      {:row, row} ->
        fetch_rows(db, statement, [row | acc])
      :done ->
        {:ok, Enum.reverse(acc)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_error(reason) when is_binary(reason) do
    %{
      message: reason,
      sqlite: %{
        error: reason
      }
    }
  end

  defp format_error(reason) do
    %{
      message: "SQLite error",
      sqlite: %{
        error: inspect(reason)
      }
    }
  end

  defp convert_parameters(query, params) when params == [], do: query
  defp convert_parameters(query, params) do
    # Convert PostgreSQL-style $1, $2 to SQLite-style ?
    params
    |> Enum.with_index(1)
    |> Enum.reduce(query, fn {_, index}, acc ->
      String.replace(acc, "$#{index}", "?")
    end)
  end

  defp version_compare(version1, version2) do
    v1_parts = version1 |> String.split(".") |> Enum.map(&String.to_integer/1)
    v2_parts = version2 |> String.split(".") |> Enum.map(&String.to_integer/1)
    
    compare_parts(v1_parts, v2_parts)
  end

  defp compare_parts([], []), do: 0
  defp compare_parts([h1 | t1], [h2 | t2]) when h1 == h2, do: compare_parts(t1, t2)
  defp compare_parts([h1 | _], [h2 | _]) when h1 > h2, do: 1
  defp compare_parts([h1 | _], [h2 | _]) when h1 < h2, do: -1
  defp compare_parts([], _), do: -1
  defp compare_parts(_, []), do: 1
end