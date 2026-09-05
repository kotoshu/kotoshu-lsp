# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kotoshu::Lsp::Protocol do
  describe ".range_from_offsets" do
    it "reports zero-based column for a word at the very start of the document" do
      text = "helo wrld\nsecond line"

      range = described_class.range_from_offsets(text, 0, 4)

      expect(range).to eq(start: { line: 0, character: 0 }, end: { line: 0, character: 4 })
    end

    it "reports zero-based column for a word starting a later line" do
      text = "first\nhelo wrld"

      range = described_class.range_from_offsets(text, 6, 10)

      expect(range).to eq(start: { line: 1, character: 0 }, end: { line: 1, character: 4 })
    end

    it "spans lines when the range crosses a newline" do
      text = "first\nsecond"

      range = described_class.range_from_offsets(text, 3, 9)

      expect(range).to eq(start: { line: 0, character: 3 }, end: { line: 1, character: 3 })
    end

    it "handles a document without newlines" do
      text = "helo"

      range = described_class.range_from_offsets(text, 1, 3)

      expect(range).to eq(start: { line: 0, character: 1 }, end: { line: 0, character: 3 })
    end

    it "handles an empty range at offset zero" do
      range = described_class.range_from_offsets("anything", 0, 0)

      expect(range).to eq(start: { line: 0, character: 0 }, end: { line: 0, character: 0 })
    end
  end
end
