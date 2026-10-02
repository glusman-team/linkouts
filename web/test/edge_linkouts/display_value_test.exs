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
end
