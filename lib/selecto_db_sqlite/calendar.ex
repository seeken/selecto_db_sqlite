defmodule SelectoDBSQLite.Calendar do
  @moduledoc false
  alias Selecto.Dialect.DateTime.Operation
  alias SelectoDBSQLite.RuntimeCapabilities

  @formats %{
    "YYYY-MM-DD" => "%Y-%m-%d",
    "YYYY-MM-DD HH24" => "%Y-%m-%d %H",
    "YYYY-MM" => "%Y-%m",
    "YYYY" => "%Y",
    "MM" => "%m",
    "DD" => "%d",
    "HH24" => "%H",
    "day" => "%Y-%m-%d",
    "time" => "%H:%M:%S",
    "day_hour" => "%Y-%m-%d %H",
    "month" => "%Y-%m",
    "year" => "%Y",
    "month_of_year" => "%m",
    "month_day" => "%m-%d",
    "day_of_month" => "%d",
    "day_of_year" => "%j",
    "hour" => "%H",
    "iso8601" => "%Y-%m-%dT%H:%M:%S",
    "rfc3339_millis" => "%Y-%m-%dT%H:%M:%fZ"
  }

  def render(%Operation{} = operation, selecto) do
    with {:ok, expression} <- expression(operation.expression, operation.options) do
      case operation.operation do
        :format ->
          format(expression, Map.get(operation.options, :format))

        :current_timestamp ->
          {:ok, "strftime('%Y-%m-%d %H:%M:%f', 'now')"}

        :extract_part ->
          extract(expression, operation.part)

        :truncate ->
          truncate(expression, operation.part)

        :elapsed_days ->
          {:ok,
           [
             "CAST(julianday('now', 'start of day') - julianday(date(",
             expression,
             ")) AS INTEGER)"
           ]}

        :temporal_cutoff ->
          cutoff(expression, operation, selecto)

        _ ->
          unsupported(operation.operation)
      end
    end
  end

  def expression(expression, options) do
    zones = [Map.get(options, :timezone), Map.get(options, :storage_timezone)]

    if Enum.all?(zones, &(&1 in [nil, "", "UTC", "Etc/UTC", "GMT", "Etc/GMT"])) do
      case Map.get(options, :epoch_storage) do
        value when value in [nil, false] ->
          {:ok, expression}

        :unix_seconds ->
          {:ok, ["strftime('%Y-%m-%d %H:%M:%f', ", expression, ", 'unixepoch')"]}

        :unix_milliseconds ->
          {:ok, ["strftime('%Y-%m-%d %H:%M:%f', (", expression, ") / 1000.0, 'unixepoch')"]}

        _ ->
          unsupported(:epoch_storage)
      end
    else
      unsupported(:timezone)
    end
  end

  def format(expression, format) do
    case Map.fetch(@formats, format) do
      {:ok, pattern} -> {:ok, strftime(pattern, expression)}
      :error -> format_special(expression, format)
    end
  end

  defp format_special(expression, format) do
    value = "selecto_calendar.value"
    year = strftime("%Y", value)
    month = integer_part("%m", value)
    iso_day = ["((", integer_part("%w", value), " + 6) % 7 + 1)"]

    result =
      case format do
        "D" ->
          ["(", integer_part("%w", value), " + 1)"]

        "day_of_week_num" ->
          iso_day

        "day_of_week" ->
          [
            "CASE ",
            strftime("%w", value),
            " WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday' WHEN '2' THEN 'Tuesday'",
            " WHEN '3' THEN 'Wednesday' WHEN '4' THEN 'Thursday' WHEN '5' THEN 'Friday' WHEN '6' THEN 'Saturday' END"
          ]

        "YYYY-Q" ->
          [year, " || '-' || CAST((", month, " + 2) / 3 AS INTEGER)"]

        "quarter" ->
          [year, " || '-Q' || CAST((", month, " + 2) / 3 AS INTEGER)"]

        "YYYY-WW" ->
          [year, " || '-' || printf('%02d', ((", integer_part("%j", value), " - 1) / 7) + 1)"]

        value_format when value_format in ["week", "iso_week", "iso_week_date"] ->
          thursday = ["date(", value, ", '-3 days', 'weekday 4')"]

          week = [
            strftime("%Y", thursday),
            " || '-W' || printf('%02d', ((",
            integer_part("%j", thursday),
            " - 1) / 7) + 1)"
          ]

          if value_format == "iso_week_date", do: [week, " || '-' || ", iso_day], else: week

        "epoch_seconds" ->
          integer_part("%s", value)

        "epoch_milliseconds" ->
          [
            "(",
            integer_part("%s", value),
            " * 1000 + CAST(substr(",
            strftime("%f", value),
            ", 4, 3) AS INTEGER))"
          ]

        "timezone_offset" ->
          "'+00:00'"

        _ ->
          nil
      end

    if result do
      {:ok,
       one_value(expression, ["CASE WHEN date(", value, ") IS NOT NULL THEN ", result, " END"])}
    else
      unsupported(:format)
    end
  end

  defp extract(expression, part) do
    value = "selecto_calendar.value"
    year = integer_part("%Y", value)
    month = integer_part("%m", value)

    result =
      case part do
        :year ->
          year

        :month ->
          month

        :day ->
          integer_part("%d", value)

        :hour ->
          integer_part("%H", value)

        :minute ->
          integer_part("%M", value)

        :second ->
          ["CAST(", strftime("%f", value), " AS REAL)"]

        :milliseconds ->
          ["CAST(", strftime("%f", value), " AS REAL) * 1000.0"]

        :epoch ->
          [
            "(",
            integer_part("%s", value),
            " + CAST(substr(",
            strftime("%f", value),
            ", 4, 3) AS REAL) / 1000.0)"
          ]

        :quarter ->
          ["CAST((", month, " + 2) / 3 AS INTEGER)"]

        :dow ->
          integer_part("%w", value)

        :isodow ->
          ["((", integer_part("%w", value), " + 6) % 7 + 1)"]

        :weekday_sunday_one ->
          ["(", integer_part("%w", value), " + 1)"]

        :doy ->
          integer_part("%j", value)

        :week ->
          [
            "CAST(((",
            integer_part("%j", ["date(", value, ", '-3 days', 'weekday 4')"]),
            " - 1) / 7) + 1 AS INTEGER)"
          ]

        :decade ->
          ["CAST(", year, " / 10 AS INTEGER)"]

        :century ->
          ["CAST((", year, " + 99) / 100 AS INTEGER)"]

        :millennium ->
          ["CAST((", year, " + 999) / 1000 AS INTEGER)"]

        unit when unit in [:timezone, :timezone_hour, :timezone_minute] ->
          "0"

        _ ->
          nil
      end

    if result,
      do:
        {:ok,
         one_value(expression, ["CASE WHEN date(", value, ") IS NOT NULL THEN ", result, " END"])},
      else: unsupported(:extract_part)
  end

  defp truncate(expression, part) do
    value = "selecto_calendar.value"

    result =
      case part do
        :year ->
          strftime("%Y-01-01 00:00:00", value)

        :month ->
          strftime("%Y-%m-01 00:00:00", value)

        :day ->
          strftime("%Y-%m-%d 00:00:00", value)

        :hour ->
          strftime("%Y-%m-%d %H:00:00", value)

        :minute ->
          strftime("%Y-%m-%d %H:%M:00", value)

        :second ->
          strftime("%Y-%m-%d %H:%M:%S", value)

        :week ->
          ["date(", value, ", 'weekday 0', '-6 days') || ' 00:00:00'"]

        :quarter ->
          [
            "printf('%s-%02d-01 00:00:00', ",
            strftime("%Y", value),
            ", ((",
            integer_part("%m", value),
            " - 1) / 3) * 3 + 1)"
          ]

        _ ->
          nil
      end

    if result,
      do:
        {:ok,
         one_value(expression, ["CASE WHEN date(", value, ") IS NOT NULL THEN ", result, " END"])},
      else: unsupported(:truncate)
  end

  defp cutoff(expression, operation, selecto) do
    amount = Map.get(operation.options, :amount)

    clock =
      case Map.get(operation.options, :clock) do
        :current_date -> "'now', 'start of day'"
        :current_timestamp -> "'now'"
        _ -> nil
      end

    units = %{
      second: {1, "seconds"},
      minute: {1, "minutes"},
      hour: {1, "hours"},
      day: {1, "days"},
      week: {7, "days"},
      month: {1, "months"},
      quarter: {3, "months"},
      year: {1, "years"}
    }

    with true <- is_number(amount) and amount >= 0 and not is_nil(clock),
         {:ok, {multiplier, unit}} <- Map.fetch(units, operation.part),
         :ok <-
           if(operation.part in [:month, :quarter, :year],
             do: RuntimeCapabilities.require_feature(selecto, :calendar_shift),
             else: :ok
           ) do
      floor = if operation.part in [:month, :quarter, :year], do: ", 'floor'", else: ""

      {:ok,
       {[
          "julianday(",
          expression,
          ") > julianday(",
          clock,
          ", (-",
          {:param, amount},
          " * ",
          Integer.to_string(multiplier),
          ") || ' ",
          unit,
          "'",
          floor,
          ")"
        ], [amount]}}
    else
      {:error, _} = error -> error
      _ -> unsupported(:temporal_cutoff)
    end
  end

  defp one_value(expression, result),
    do: ["(SELECT ", result, " FROM (SELECT ", expression, " AS value) AS selecto_calendar)"]

  defp strftime(pattern, expression), do: ["strftime('", pattern, "', ", expression, ")"]

  defp integer_part(pattern, expression),
    do: ["CAST(", strftime(pattern, expression), " AS INTEGER)"]

  defp unsupported(operation),
    do:
      {:error,
       Selecto.Error.validation_error("SQLite does not support this datetime operation", %{
         operation: operation,
         unsupported_feature: :datetime_operation
       })}
end
