defmodule CcInspectorWeb.FormatTest do
  use ExUnit.Case, async: true

  import CcInspectorWeb.Format

  describe "abbrev_number/1" do
    test "leaves numbers under a thousand alone" do
      assert abbrev_number(0) == "0"
      assert abbrev_number(999) == "999"
    end

    test "scales to K, M, B, and T with one decimal" do
      assert abbrev_number(1_234) == "1.2K"
      assert abbrev_number(853_722_909) == "853.7M"
      assert abbrev_number(1_682_322_109) == "1.7B"
      assert abbrev_number(2_500_000_000_000) == "2.5T"
    end

    test "drops a trailing zero decimal" do
      assert abbrev_number(2_000_000) == "2M"
      assert abbrev_number(5_000) == "5K"
    end

    test "handles nil and negatives" do
      assert abbrev_number(nil) == "0"
      assert abbrev_number(-1_500) == "-1.5K"
    end
  end

  describe "percent_delta/1" do
    test "signs the value and marks it as a percentage" do
      assert percent_delta(12.5) == "+12.5%"
      assert percent_delta(-23.9) == "−23.9%"
      assert percent_delta(0) == "+0.0%"
    end

    test "renders an em dash when there is no comparison" do
      assert percent_delta(nil) == "—"
    end
  end
end
