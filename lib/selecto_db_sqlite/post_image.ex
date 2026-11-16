defmodule SelectoDBSQLite.PostImage do
  @moduledoc false
  alias Selecto.Write.{Command, Error}

  # Evaluate the scope in the write's own RETURNING, after storage coercion,
  # defaults and BEFORE triggers. Host triggers, rules and owner DDL are
  # outside the governed-write boundary.
  @truth "selecto_post_image_truth"

  def prepare(%Command{metadata: %{post_image: %{predicate: _}}, operation: operation} = command)
      when operation in [:insert, :update, :upsert], do: {:post_image, command}

  def prepare(command), do: {:plain, command}

  def returning(statement, command, compile_predicate) do
    with {:ok, scope} <- compile_predicate.(command.metadata.post_image.predicate) do
      prefix = if command.returning == :none, do: " RETURNING ", else: ", "

      {:ok,
       %{
         statement
         | text:
             statement.text <>
               prefix <> "CASE WHEN (#{scope.text}) THEN 1 ELSE 0 END AS #{@truth}",
           params: statement.params ++ scope.params
       }}
    end
  end

  def verify(%{columns: columns, rows: rows} = result) when is_list(columns) and is_list(rows) do
    index = length(columns) - 1

    cond do
      List.last(columns) != @truth ->
        refused(:query_rule_not_evaluable, "cannot read the written rows' scope")

      Enum.any?(rows, &(Enum.at(&1, index) != 1)) ->
        refused(:query_rule_violation, "the written rows left the trusted write scope")

      true ->
        kept = List.delete_at(columns, index)

        {:ok,
         %{
           result
           | columns: kept,
             rows: if(kept == [], do: [], else: Enum.map(rows, &List.delete_at(&1, index)))
         }}
    end
  end

  def verify(_), do: refused(:query_rule_not_evaluable, "cannot read the written rows' scope")

  defp refused(code, message),
    do:
      {:error,
       Error.new(:query_enforcement, "SQLite " <> message,
         details: %{code: code, adapter: :sqlite}
       )}
end
