defmodule SelectoDBSQLite.Buckets do
  @moduledoc false
  alias Selecto.Dialect.Bucket.Expression
  alias Selecto.Dialect.Text.Normalization, as: TextNormalization
  alias SelectoDBSQLite.Calendar

  def render(%Expression{} = bucket, _selecto) do
    with {:ok, source} <- Calendar.expression(bucket.expression, bucket.temporal_options),
         {:ok, result} <- result(%{bucket | expression: "selecto_bucket.value"}) do
      {:ok, ["(SELECT ", result, " FROM (SELECT ", source, " AS value) AS selecto_bucket)"]}
    else
      {:error, %Selecto.Error{}} = error -> error
      {:error, reason} -> invalid(reason)
    end
  end

  def normalize(%TextNormalization{} = normalization) do
    articles = normalization.exclude_articles

    if is_list(articles) and Enum.all?(articles, &(is_binary(&1) and String.trim(&1) != "")) do
      base = ["TRIM(CAST(", normalization.expression, " AS TEXT))"]
      value = "selecto_text.value"

      clauses =
        Enum.map(articles, fn article ->
          size = String.length(article)
          cmp = if normalization.ignore_case, do: ["lower(", value, ")"], else: value
          article = if normalization.ignore_case, do: String.downcase(article), else: article

          [
            "WHEN ",
            cmp,
            " = ",
            {:param, article},
            " THEN '' WHEN substr(",
            cmp,
            ", 1, ",
            Integer.to_string(size + 1),
            ") = ",
            {:param, article <> " "},
            " THEN ltrim(substr(",
            value,
            ", ",
            Integer.to_string(size + 2),
            ")) "
          ]
        end)

      stripped = if clauses == [], do: value, else: ["CASE ", clauses, " ELSE ", value, " END"]
      output = if normalization.ignore_case, do: ["lower(", stripped, ")"], else: stripped
      {:ok, ["(SELECT ", output, " FROM (SELECT ", base, " AS value) AS selecto_text)"]}
    else
      invalid(:invalid_articles)
    end
  end

  defp result(%Expression{kind: kind, increment: increment} = bucket)
       when kind in [:numeric_increment, :year_increment] and is_integer(increment) and
              increment > 0 do
    value = if kind == :year_increment, do: year(bucket.expression), else: bucket.expression
    divisor = Integer.to_string(increment)
    # Integer inputs retain all signed 64-bit bits. Negative remainders require
    # one downward correction; real inputs use the same truncation correction.
    quotient = ["(", value, " / ", divisor, ")"]

    floor = [
      "(CAST(",
      quotient,
      " AS INTEGER) - CASE WHEN typeof(",
      value,
      ") = 'integer' THEN (",
      value,
      " < 0 AND ",
      value,
      " % ",
      divisor,
      " != 0) ELSE (",
      quotient,
      " < CAST(",
      quotient,
      " AS INTEGER)) END)"
    ]

    start = ["(", floor, " * ", divisor, ")"]

    {:ok,
     [
       "CASE WHEN ",
       value,
       " IS NULL THEN 'Other' ELSE CAST(",
       start,
       " AS TEXT) || '-' || CAST((",
       start,
       " + ",
       Integer.to_string(increment - 1),
       ") AS TEXT) END"
     ]}
  end

  defp result(%Expression{kind: :text_prefix, prefix_length: length} = bucket)
       when is_integer(length) and length > 0 do
    with {:ok, normalized} <-
           normalize(%TextNormalization{
             expression: bucket.expression,
             exclude_articles: bucket.exclude_articles,
             ignore_case: bucket.ignore_case
           }) do
      {:ok,
       [
         "(SELECT CASE WHEN value IS NULL OR value = '' THEN 'Other' ELSE UPPER(SUBSTR(value, 1, ",
         Integer.to_string(length),
         ")) END FROM (SELECT ",
         normalized,
         " AS value))"
       ]}
    end
  end

  defp result(%Expression{kind: kind, ranges: [_ | _] = ranges} = bucket)
       when kind in [:numeric_ranges, :year_ranges, :elapsed_days_ranges, :date_relative_ranges] do
    value =
      case kind do
        :year_ranges ->
          year(bucket.expression)

        :elapsed_days_ranges ->
          [
            "CAST(julianday('now', 'start of day') - julianday(date(",
            bucket.expression,
            ")) AS INTEGER)"
          ]

        :date_relative_ranges ->
          ["DATE(", bucket.expression, ")"]

        _ ->
          bucket.expression
      end

    clauses = Enum.map(ranges, &range(value, &1, kind == :date_relative_ranges))

    if Enum.all?(clauses, &match?({:ok, _}, &1)),
      do:
        {:ok,
         ["CASE ", Enum.intersperse(Enum.map(clauses, &elem(&1, 1)), " "), " ELSE 'Other' END"]},
      else: {:error, :invalid_range}
  end

  defp result(_), do: {:error, :unsupported_bucket_shape}

  defp range(value, {keyword, keyword, label}, true)
       when keyword in ["today", "yesterday", "tomorrow"] and is_binary(label) do
    day =
      case keyword do
        "today" -> "DATE('now')"
        "yesterday" -> "DATE('now', '-1 day')"
        "tomorrow" -> "DATE('now', '+1 day')"
      end

    {:ok, ["WHEN ", value, " = ", day, " THEN ", {:param, label}]}
  end

  defp range(value, {minimum, maximum, label}, relative) when is_binary(label) do
    cond do
      is_integer(minimum) and is_integer(maximum) and minimum <= maximum ->
        if relative do
          {:ok,
           [
             "WHEN ",
             value,
             " BETWEEN ",
             days_ago(maximum),
             " AND ",
             days_ago(minimum),
             " THEN ",
             {:param, label}
           ]}
        else
          {:ok,
           [
             "WHEN ",
             value,
             " >= ",
             Integer.to_string(minimum),
             " AND ",
             value,
             " <= ",
             Integer.to_string(maximum),
             " THEN ",
             {:param, label}
           ]}
        end

      is_integer(minimum) and maximum == :infinity ->
        {:ok,
         [
           "WHEN ",
           value,
           if(relative, do: " <= ", else: " >= "),
           if(relative, do: days_ago(minimum), else: Integer.to_string(minimum)),
           " THEN ",
           {:param, label}
         ]}

      minimum == :negative_infinity and is_integer(maximum) ->
        {:ok,
         [
           "WHEN ",
           value,
           if(relative, do: " >= ", else: " <= "),
           if(relative, do: days_ago(maximum), else: Integer.to_string(maximum)),
           " THEN ",
           {:param, label}
         ]}

      true ->
        {:error, :invalid_range}
    end
  end

  defp range(_, _, _), do: {:error, :invalid_range}
  defp days_ago(days), do: ["DATE('now', '", Integer.to_string(-days), " day')"]
  defp year(value), do: ["CAST(strftime('%Y', ", value, ") AS INTEGER)"]

  defp invalid(reason),
    do:
      {:error,
       Selecto.Error.validation_error("Invalid SQLite bucket expression", %{
         unsupported_feature: :bucket_expression,
         reason: reason
       })}
end
