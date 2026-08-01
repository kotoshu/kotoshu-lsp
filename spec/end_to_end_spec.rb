# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "kotoshu-lsp end-to-end over stdio" do
  let(:ruby) { RbConfig.ruby }
  let(:exe) { File.expand_path("../exe/kotoshu-lsp", __dir__) }

  def with_server
    stdin_r, stdin_w = IO.pipe
    stdout_r, stdout_w = IO.pipe
    pid = spawn(ruby, exe, in: stdin_r, out: stdout_w, err: [:child, :out])
    stdin_r.close
    stdout_w.close
    yield Client.new(stdin_w, stdout_r)
  ensure
    stdin_w.close unless stdin_w.closed?
    stdout_r.close unless stdout_r.closed?
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  class Client
    def initialize(stdin, stdout)
      @stdin = stdin
      @stdout = stdout
      @mutex = Mutex.new
      @id = 0
    end

    def request(method, params = nil)
      @mutex.synchronize do
        @id += 1
        send_message(id: @id, method: method, params: params)
        read_until_match(@id)
      end
    end

    def notify(method, params = nil)
      @mutex.synchronize { send_message(method: method, params: params) }
    end

    def wait_for_notification(method, timeout: 5.0)
      @mutex.synchronize do
        deadline = Time.now + timeout
        while Time.now < deadline
          msg = read_message
          return msg if msg && msg["method"] == method
        end
        nil
      end
    end

    private

    def send_message(hash)
      payload = JSON.generate(hash)
      header = "Content-Length: #{payload.bytesize}\r\n\r\n"
      @stdin.write(header)
      @stdin.write(payload)
      @stdin.flush
    end

    def read_until_match(id)
      loop do
        msg = read_message
        return msg["result"] if msg && msg["id"] == id
        return msg if msg && msg["id"] == id && msg.key?("error")
      end
    end

    def read_message
      headers = {}
      loop do
        line = @stdout.gets
        return nil if line.nil?
        line = line.chomp
        break if line.empty?

        k, v = line.split(":", 2)
        headers[k.strip.downcase] = v.strip
      end
      length = headers.fetch("content-length").to_i
      body = @stdout.read(length)
      JSON.parse(body)
    end
  end

  it "answers initialize" do
    with_server do |client|
      result = client.request("initialize", { processId: Process.pid, capabilities: {} })
      expect(result["serverInfo"]["name"]).to eq("kotoshu-lsp")
      expect(result.dig("capabilities", "textDocumentSync", "openClose")).to eq(true)
    end
  end

  it "publishes diagnostics on didOpen for a misspelled word" do
    with_server do |client|
      client.request("initialize")
      client.notify("initialized")
      client.notify("textDocument/didOpen", {
        textDocument: {
          uri: "file:///tmp/test.txt",
          languageId: "plaintext",
          version: 1,
          text: "helo wrold"
        }
      })
      notif = client.wait_for_notification("textDocument/publishDiagnostics")
      expect(notif).not_to be_nil
      params = notif["params"]
      expect(params["uri"]).to eq("file:///tmp/test.txt")
      words = params["diagnostics"].map { |d| d["message"] }
      expect(words.any? { |m| m.include?("helo") }).to eq(true)
    end
  end

  it "suggests code actions to fix a flagged word" do
    with_server do |client|
      client.request("initialize")
      client.notify("initialized")
      client.notify("textDocument/didOpen", {
        textDocument: {
          uri: "file:///tmp/test2.txt",
          languageId: "plaintext",
          version: 1,
          text: "helo"
        }
      })
      notif = client.wait_for_notification("textDocument/publishDiagnostics")
      diag = notif["params"]["diagnostics"].first

      actions = client.request("textDocument/codeAction", {
        textDocument: { uri: "file:///tmp/test2.txt" },
        range: diag["range"],
        context: { diagnostics: [diag] }
      })
      expect(actions).to be_an(Array)
      titles = actions.map { |a| a["title"] }
      expect(titles.any? { |t| t.start_with?("Kotoshu: change to") }).to eq(true)
      expect(titles.any? { |t| t.include?("personal dictionary") }).to eq(true)
    end
  end
end
