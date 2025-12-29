# frozen_string_literal: true

RSpec.describe Clacky::Conversation do
  let(:api_key) { "test-api-key" }
  let(:conversation) { described_class.new(api_key) }
  let(:client) { instance_double(Clacky::Client) }

  before do
    allow(Clacky::Client).to receive(:new).with(api_key, base_url: "https://api.openai.com").and_return(client)
  end

  describe "#initialize" do
    it "creates a new conversation with empty messages" do
      expect(conversation.messages).to be_empty
    end

    it "creates a client with the provided API key" do
      described_class.new(api_key)
      expect(Clacky::Client).to have_received(:new).with(api_key, base_url: "https://api.openai.com")
    end
  end

  describe "#send_message" do
    let(:user_message) { "Hello, Claude!" }
    let(:assistant_response) { "Hello! How can I help you today?" }

    before do
      allow(client).to receive(:send_messages).and_return(assistant_response)
    end

    it "adds user message to history" do
      conversation.send_message(user_message)

      expect(conversation.messages).to include(
        hash_including(role: "user", content: user_message)
      )
    end

    it "adds assistant response to history" do
      conversation.send_message(user_message)

      expect(conversation.messages).to include(
        hash_including(role: "assistant", content: assistant_response)
      )
    end

    it "maintains conversation order" do
      conversation.send_message("First message")
      conversation.send_message("Second message")

      expect(conversation.messages.size).to eq(4) # 2 user + 2 assistant
      expect(conversation.messages[0][:role]).to eq("user")
      expect(conversation.messages[1][:role]).to eq("assistant")
      expect(conversation.messages[2][:role]).to eq("user")
      expect(conversation.messages[3][:role]).to eq("assistant")
    end

    it "returns the assistant's response" do
      response = conversation.send_message(user_message)
      expect(response).to eq(assistant_response)
    end
  end

  describe "#clear" do
    it "removes all messages from history" do
      allow(client).to receive(:send_messages).and_return("Response")
      conversation.send_message("Test message")

      conversation.clear

      expect(conversation.messages).to be_empty
    end
  end

  describe "#history" do
    it "returns a copy of messages array" do
      allow(client).to receive(:send_messages).and_return("Response")
      conversation.send_message("Test")

      history = conversation.history
      history << { role: "user", content: "Modified" }

      expect(conversation.messages.size).not_to eq(history.size)
    end
  end
end
