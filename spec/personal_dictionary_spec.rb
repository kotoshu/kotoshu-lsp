# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

RSpec.describe "kotoshu-lsp personal dictionary integration" do
  let(:ruby) { RbConfig.ruby }
  let(:exe) { File.expand_path("../exe/kotoshu-lsp", __dir__) }
  let(:personal_dic) { File.join(Dir.mktmpdir("kotoshu-lsp-pd"), "personal.dic") }

  def with_server
    stdin_r, stdin_w = IO.pipe
    stdout_r, stdout_w = IO.pipe
    env = ENV.to_h.merge("KOTOSHU_PERSONAL_DIC" => personal_dic)
    pid = spawn(env, ruby, exe, in: stdin_r, out: stdout_w, err: [:child, :out])
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
      @pending_notifications = []
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
        queued = @pending_notifications.find { |m| m["method"] == method }
        return queued if queued

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
      @stdin.write(header + payload)
    end

    def read_message
      length = nil
      while (line = @stdout.gets("\r\n"))
        break if line.strip.empty?
        length = Regexp.last_match(1).to_i if line =~ /Content-Length:\s*(\d+)/i
      end
      return nil unless length
      body = @stdout.read(length)
      JSON.parse(body)
    end

    def read_until_match(id)
      deadline = Time.now + 10.0
      while Time.now < deadline
        msg = read_message
        next unless msg
        return msg["result"] if msg["id"] == id && msg.key?("result")
        raise msg["error"].inspect if msg["id"] == id && msg.key?("error")
        @pending_notifications << msg if msg["method"]
      end
      nil
    end
  end

  def open_document(client, uri, text)
    client.request("initialize")
    client.notify("initialized")
    client.notify("textDocument/didOpen", {
      textDocument: { uri: uri, languageId: "plaintext", version: 1, text: text }
    })
    client.wait_for_notification("textDocument/publishDiagnostics")
  end

  it "declares the add-to-personal-dictionary command" do
    with_server do |client|
      result = client.request("initialize", { processId: Process.pid, capabilities: {} })
      commands = result.dig("capabilities", "executeCommandProvider", "commands")
      expect(commands).to eq(["kotoshu.addToPersonalDictionary"])
    end
  end

  it "suppresses diagnostics for words already in the personal dictionary" do
    File.write(personal_dic, "Kotoshu\n")
    with_server do |client|
      notif = open_document(client, "file:///tmp/pd-existing.txt", "Kotoshu helo")
      words = notif["params"]["diagnostics"].map { |d| d["message"] }
      expect(words.none? { |m| m.include?("Kotoshu") }).to eq(true)
      expect(words.any? { |m| m.include?("helo") }).to eq(true)
    end
  end

  it "adds the word server-side and republishes clean diagnostics" do
    with_server do |client|
      notif = open_document(client, "file:///tmp/pd-add.txt", "helo wrld")
      diag = notif["params"]["diagnostics"].first
      expect(diag).not_to be_nil

      result = client.request("workspace/executeCommand", {
        command: "kotoshu.addToPersonalDictionary",
        arguments: ["file:///tmp/pd-add.txt", diag["range"]]
      })
      expect(result).to be_nil
      expect(File.read(personal_dic)).to include("helo")

      republished = client.wait_for_notification("textDocument/publishDiagnostics")
      words = republished["params"]["diagnostics"].map { |d| d["message"] }
      expect(words.none? { |m| m.include?("helo") }).to eq(true)
      expect(words.any? { |m| m.include?("wrld") }).to eq(true)
    end
  end

  it "picks up dictionary additions made on disk between checks" do
    with_server do |client|
      notif = open_document(client, "file:///tmp/pd-disk.txt", "helo")
      expect(notif["params"]["diagnostics"].length).to eq(1)

      File.write(personal_dic, "helo\n")
      client.notify("textDocument/didChange", {
        textDocument: { uri: "file:///tmp/pd-disk.txt", version: 2 },
        contentChanges: [{ text: "helo wrold" }]
      })
      notif2 = client.wait_for_notification("textDocument/publishDiagnostics")
      words = notif2["params"]["diagnostics"].map { |d| d["message"] }
      expect(words.none? { |m| m.include?("helo") }).to eq(true)
      expect(words.any? { |m| m.include?("wrold") }).to eq(true)
    end
  end

  it "returns nil for an unknown command" do
    with_server do |client|
      client.request("initialize")
      result = client.request("workspace/executeCommand", {
        command: "some.otherCommand", arguments: []
      })
      expect(result).to be_nil
    end
  end
end
