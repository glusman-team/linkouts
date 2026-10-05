defmodule EdgeLinkouts.Display.ValueTest do
  use ExUnit.Case, async: true

  alias EdgeLinkouts.Display.{Segment, Value}

  defp number(value, format) do
    ctx = %{doc: %{"n" => value}, version: "kg-1.0.0", slots: %{}, aliases: %{}}
    {:number, "n", format} |> Value.render(ctx) |> Segment.to_text()
  end

  describe "{:number, field, :sig2}" do
    test "p-value magnitudes use unpadded scientific notation" do
      # Erlang's own output is "1.2e-09"; a reader expects "1.2e-9".
      assert number(0.0000000012, :sig2) == "1.2e-9"
      assert number(0.00045, :sig2) == "4.5e-4"
      assert number(123_456.0, :sig2) == "1.2e5"
    end

    test "ordinary magnitudes print plainly at two significant digits" do
      assert number(0.123456, :sig2) == "0.12"
      assert number(-0.42, :sig2) == "-0.42"
      assert number(0.0123, :sig2) == "0.012"
      assert number(12.34, :sig2) == "12"
      assert number(3.0, :sig2) == "3"
    end

    test "zero, integers and non-numbers pass through" do
      assert number(0.0, :sig2) == "0"
      assert number(7, :sig2) == "7"
      # Sources spell a missing number "NA"; it must not become 0 or crash.
      assert number("NA", :sig2) == "NA"
    end
  end

  describe "{:number, field, :int}" do
    test "rounds floats the way the legacy sprintf(\"%.0f\") did" do
      assert number(412.0, :int) == "412"
      assert number(411.6, :int) == "412"
      assert number(9, :int) == "9"
    end
  end

  describe "{:local, field}" do
    test "a CURIE renders as its local id" do
      ctx = %{
        doc: %{"p" => "biolink:applied_to_treat"},
        version: "kg-1.0.0",
        slots: %{},
        aliases: %{}
      }

      assert {:local, "p"} |> Value.render(ctx) |> Segment.to_text() == "applied_to_treat"
    end

    test "a value with no prefix passes through; a missing field renders nothing" do
      ctx = %{doc: %{"c" => "CHEBI:1234"}, version: "kg-1.0.0", slots: %{}, aliases: %{}}

      assert {:local, "c"} |> Value.render(ctx) |> Segment.to_text() == "1234"
      assert {:local, "missing"} |> Value.render(ctx) == []
    end

    test "a url template resolves slots before fields, so a local id can build a docs link" do
      ctx = %{
        doc: %{"p" => "biolink:treats"},
        version: "kg-1.0.0",
        slots: %{"local" => {:local, "p"}, "words" => {:humanize, "p"}},
        aliases: %{}
      }

      spec = {:url, "https://biolink.github.io/biolink-model/{local}/", "{words}"}
      assert [{:link, href, "treats"}] = Value.render(spec, ctx)
      assert href == "https://biolink.github.io/biolink-model/treats/"
    end
  end

  describe "{:list, field, inner, separator, max}" do
    defp list_ctx do
      %{
        doc: %{
          "ps" => ["dailymed:a1", "dailymed:b2", "dailymed:c3", "dailymed:d4", "dailymed:e5"]
        },
        version: "kg-1.0.0",
        slots: %{},
        aliases: %{}
      }
    end

    test "the first max items stay inline and the rest fold into one {:more} segment" do
      segments = Value.render({:list, "ps", {:field, "self"}, ", ", 2}, list_ctx())

      assert [{:text, prefix}, {:more, hidden}] = segments
      assert prefix =~ "dailymed:a1, dailymed:b2"
      # The fold carries its leading separator, so a flattened read is the full list.
      assert Segment.to_text(hidden) == ", dailymed:c3, dailymed:d4, dailymed:e5"

      assert Segment.to_text(segments) ==
               "dailymed:a1, dailymed:b2, dailymed:c3, dailymed:d4, dailymed:e5"
    end

    test "a list that fits under the cap renders with no fold at all" do
      segments = Value.render({:list, "ps", {:field, "self"}, ", ", 9}, list_ctx())

      refute Enum.any?(segments, &match?({:more, _}, &1))

      assert Segment.to_text(segments) ==
               "dailymed:a1, dailymed:b2, dailymed:c3, dailymed:d4, dailymed:e5"
    end
  end
end
