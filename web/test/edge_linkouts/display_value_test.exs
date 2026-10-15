defmodule EdgeLinkouts.Display.ValueTest do
  use ExUnit.Case, async: true

  alias EdgeLinkouts.Display.{Segment, Value}

  defp number(value, format) do
    ctx = %{doc: %{"n" => value}, version: "kg-1.0.0", slots: %{}, aliases: %{}}
    {:number, "n", format} |> Value.render(ctx) |> Segment.to_text()
  end

  describe "{:names, field}" do
    test "pipe-delimited originals use Oxford commas and omit blanks and duplicates" do
      for {value, expected} <- [
            {"Zyrtec", "Zyrtec"},
            {"A|B", "A and B"},
            {" A | B | C | A || ", "A, B, and C"},
            {["A|B", "C"], "A, B, and C"},
            {nil, ""},
            {" | ", ""}
          ] do
        ctx = %{doc: %{"original" => value}, version: "kg-1.0.0", slots: %{}, aliases: %{}}
        assert Value.render({:names, "original"}, ctx) |> Segment.to_text() == expected

        framed = Value.render({:names, "original", "Original: ", "."}, ctx) |> Segment.to_text()
        assert framed == if(expected == "", do: "", else: "Original: #{expected}.")
      end
    end
  end

  describe "compound mappings" do
    test "empty clauses drop, one stays a sentence, and two become a compound sentence" do
      ctx = %{doc: %{}, version: "kg-1.0.0", slots: %{}, aliases: %{}}

      for {clauses, expected} <- [
            {[], ""},
            {[nil, "The subject mapped to X:1"], "The subject mapped to X:1."},
            {["The subject mapped to X:1", "The object mapped to Y:2"],
             "The subject mapped to X:1; and the object mapped to Y:2."}
          ] do
        assert Value.render({:compound, clauses}, ctx) |> Segment.to_text() == expected
      end
    end

    test "continuation clauses downcase word openers but never CURIE prefixes" do
      ctx = %{
        doc: %{"x" => "MESH:D001"},
        version: "kg-1.0.0",
        slots: %{"x" => {:link, "x", "x"}},
        aliases: %{}
      }

      text =
        Value.render({:compound, ["The subject mapped to X:1", "Gene family {x} involved"]}, ctx)
        |> Segment.to_text()

      assert text == "The subject mapped to X:1; and gene family MESH:D001 involved."
    end

    test "a blank field falls back to the supporting_text log" do
      for blank <- ["", []] do
        ctx = %{
          doc: %{
            "original_subject" => blank,
            "supporting_text" => ["original_subject: Zyrtec|Cetirizine"]
          },
          version: "kg-1.0.0",
          slots: %{},
          aliases: %{}
        }

        assert Value.render({:names, "original_subject"}, ctx) |> Segment.to_text() ==
                 "Zyrtec and Cetirizine"
      end
    end

    test "qualifier originals also resolve pipe-delimited supporting-text entries" do
      ctx = %{
        doc: %{"supporting_text" => ["original_sex_qualifier: male|men"]},
        version: "kg-1.0.0",
        slots: %{},
        aliases: %{}
      }

      assert Value.render({:names, "original_sex_qualifier"}, ctx) |> Segment.to_text() ==
               "male and men"
    end
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
