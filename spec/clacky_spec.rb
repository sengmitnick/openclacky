# frozen_string_literal: true

RSpec.describe Clacky do
  it "has a version number" do
    expect(Clacky::VERSION).not_to be nil
  end

  it "defines the main module" do
    expect(Clacky).to be_a(Module)
  end

  it "defines the Error class" do
    expect(Clacky::Error).to be < StandardError
  end
end
