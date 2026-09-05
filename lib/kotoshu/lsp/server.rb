# frozen_string_literal: true

require "logger"
require "json"
require "kotoshu"

module Kotoshu
  module Lsp
    module Protocol
      DIAGNOSTIC_SEVERITY = {
        error: 1,
        warning: 2,
        information: 3,
        hint: 4
      }.freeze

      COMPLETION_TRIGGER_KIND = { invoked: 0, character: 2 }.freeze

      module_function

      def range_from_offsets(text, start_offset, end_offset)
        line_start = line_of(text, start_offset)
        char_start = start_offset - line_begin(text, start_offset)
        line_end = line_of(text, end_offset)
        char_end = end_offset - line_begin(text, end_offset)
        {
          start: { line: line_start, character: char_start },
          end:   { line: line_end, character: char_end }
        }
      end

      def line_of(text, offset)
        text[0...offset].count("\n")
      end

      def line_begin(text, offset)
        return 0 if offset <= 0

        last_nl = text.rindex("\n", offset - 1)
        last_nl ? last_nl + 1 : 0
      end
    end

    class DocumentStore
      def initialize
        @docs = {}
        @mutex = Mutex.new
      end

      def set(uri, text, language_id = nil)
        @mutex.synchronize do
          @docs[uri] = { text: text, language_id: language_id, version: 0 }
        end
      end

      def update(uri, text, version: nil)
        @mutex.synchronize do
          doc = @docs[uri]
          return unless doc

          doc[:text] = text
          doc[:version] = version if version
        end
      end

      def remove(uri)
        @mutex.synchronize { @docs.delete(uri) }
      end

      def get(uri)
        @mutex.synchronize { @docs[uri] }
      end

      def text(uri)
        doc = get(uri)
        doc ? doc[:text] : nil
      end
    end

    class Checker
      def initialize(logger:)
        @logger = logger
        @spellcheckers = {}
        @spellcheckers_mutex = Mutex.new
      end

      def reset
        @spellcheckers_mutex.synchronize { @spellcheckers.clear }
      end

      def check(text, language:)
        Kotoshu.reset_spellchecker if @spellcheckers.empty?

        checker = checker_for(language)
        return empty_result(text) unless checker

        checker.check(text)
      rescue Kotoshu::ResourceNotSetupError => e
        @logger.warn("resource not set up for #{language}: #{e.message}")
        nil
      rescue StandardError => e
        @logger.error("check failed: #{e.class}: #{e.message}")
        nil
      end

      private

      def checker_for(language)
        @spellcheckers_mutex.synchronize do
          @spellcheckers[language] ||= begin
            bundle = Kotoshu::ResourceManager.resolve(language: language)
            Kotoshu::Spellchecker.new(resource_bundle: bundle)
          rescue Kotoshu::ResourceNotSetupError
            Kotoshu.setup(language)
            bundle = Kotoshu::ResourceManager.resolve(language: language)
            Kotoshu::Spellchecker.new(resource_bundle: bundle)
          end
        end
      rescue StandardError => e
        @logger.warn("could not resolve checker for #{language}: #{e.message}")
        nil
      end

      def empty_result(_text)
        Kotoshu::Models::Result::DocumentResult.success
      end
    end

    class DiagnosticsBuilder
      MAX_SUGGESTIONS_PER_DIAG = 5

      def self.from_result(document_result, full_text, source: "kotoshu")
        return [] unless document_result&.errors

        document_result.errors.map do |err|
          from_word_error(err, full_text, source: source)
        end
      end

      def self.from_word_error(word_error, full_text, source: "kotoshu")
        start_offset = word_error.position || 0
        end_offset = start_offset + word_error.word.length
        range = Protocol.range_from_offsets(full_text, start_offset, end_offset)
        suggestions = word_error.suggestions.first(MAX_SUGGESTIONS_PER_DIAG).map(&:word)

        {
          range: range,
          severity: Protocol::DIAGNOSTIC_SEVERITY[:warning],
          code: "misspelled",
          source: source,
          message: "Misspelled word: #{word_error.word}",
          data: { suggestions: suggestions }
        }
      end
    end

    class Server
      CAPABILITIES = {
        textDocumentSync: { openClose: true, change: 1, save: false },
        completionProvider: { resolveProvider: false, triggerCharacters: [] },
        codeActionProvider: true,
        hoverProvider: true
      }.freeze

      attr_reader :documents, :checker

      def initialize(input: $stdin, output: $stdout, logger: nil)
        @input = input
        @output = output
        @logger = logger || self.class.default_logger
        @documents = DocumentStore.new
        @checker = Checker.new(logger: @logger)
        @shutdown_requested = false
        @output_mutex = Mutex.new
      end

      def self.default_logger
        log_path = ENV.fetch("KOTOSHU_LSP_LOG", nil)
        logger = log_path ? Logger.new(File.open(log_path, "a")) : Logger.new(IO::NULL)
        logger.level = ENV.fetch("KOTOSHU_LSP_LOG_LEVEL", "info").to_i
        logger
      end

      def run
        @logger.info("kotoshu-lsp server starting")
        loop do
          message = read_message
          break if message.nil?
          break if @shutdown_requested && message["method"] != "exit"

          handle(message)
        end
        @logger.info("kotoshu-lsp server exiting")
      rescue Interrupt
        @logger.info("interrupted")
      rescue StandardError => e
        @logger.error("fatal: #{e.class}: #{e.message}")
        @logger.error(e.backtrace.first(15).join("\n"))
        raise
      end

      private

      def handle(message)
        method_name = message["method"]
        params = message["params"] || {}
        id = message["id"]

        case method_name
        when "initialize" then respond(id, handle_initialize(params))
        when "initialized" then log(:info, "client initialized")
        when "shutdown" then @shutdown_requested = true; respond(id, nil)
        when "exit" then @shutdown_requested = true
        when "textDocument/didOpen" then handle_did_open(params)
        when "textDocument/didChange" then handle_did_change(params)
        when "textDocument/didClose" then handle_did_close(params)
        when "textDocument/codeAction" then respond(id, handle_code_action(params))
        when "textDocument/hover" then respond(id, handle_hover(params))
        when "textDocument/completion" then respond(id, nil)
        else
          respond_error(id, -32601, "Method not found: #{method_name}") if id
        end
      end

      def handle_initialize(params)
        {
          capabilities: CAPABILITIES,
          serverInfo: { name: "kotoshu-lsp", version: Kotoshu::VERSION }
        }
      end

      def handle_did_open(params)
        td = params["textDocument"] || {}
        uri = td["uri"]
        text = td["text"] || ""
        language_id = td["languageId"]
        @documents.set(uri, text, language_id)

        publish_diagnostics(uri, text, language_id_for(uri, language_id))
      end

      def handle_did_change(params)
        td = params["textDocument"] || {}
        uri = td["uri"]
        changes = params["contentChanges"] || []
        new_text = changes.last&.fetch("text")
        return unless new_text

        @documents.update(uri, new_text, version: td["version"])
        doc = @documents.get(uri)
        publish_diagnostics(uri, new_text, language_id_for(uri, doc&.fetch(:language_id, nil)))
      end

      def handle_did_close(params)
        uri = (params["textDocument"] || {})["uri"]
        @documents.remove(uri)
        send_notification("textDocument/publishDiagnostics", { uri: uri, diagnostics: [] })
      end

      def publish_diagnostics(uri, text, language)
        result = @checker.check(text, language: language)
        diagnostics = result ? DiagnosticsBuilder.from_result(result, text) : []
        send_notification("textDocument/publishDiagnostics",
                          { uri: uri, diagnostics: diagnostics })
      end

      def handle_code_action(params)
        td = params["textDocument"] || {}
        uri = td["uri"]
        context = params["context"] || {}
        range = params["range"] || {}

        diags = context["diagnostics"] || []
        actions = []
        diags.each do |diag|
          suggestions = (diag["data"] && diag["data"]["suggestions"]) || []
          suggestions.each_with_index do |word, idx|
            actions << code_action_replace(uri, diag["range"], word, idx.zero?)
          end
          actions << code_action_add_to_personal_dict(uri, diag["range"])
        end
        actions
      end

      def code_action_replace(uri, range, replacement, preferred)
        action = {
          title: "Kotoshu: change to \"#{replacement}\"",
          kind: "quickfix",
          edit: {
            changes: { uri => [{ range: range, newText: replacement }] }
          }
        }
        action[:isPreferred] = true if preferred
        action
      end

      def code_action_add_to_personal_dict(uri, range)
        {
          title: "Kotoshu: add word to personal dictionary",
          kind: "quickfix",
          command: {
            title: "Add to personal dictionary",
            command: "kotoshu.addToPersonalDictionary",
            arguments: [uri, range]
          }
        }
      end

      def handle_hover(params)
        td = params["textDocument"] || {}
        uri = td["uri"]
        pos = params["position"] || {}
        text = @documents.text(uri)
        return nil unless text

        offset = offset_for_position(text, pos["line"] || 0, pos["character"] || 0)
        return nil unless offset

        word = word_at(text, offset)
        return nil unless word && !word.empty?

        result = @checker.check(word, language: language_id_for(uri, @documents.get(uri)&.fetch(:language_id, nil)))
        err = result&.errors&.first
        return nil unless err

        {
          contents: [
            "Misspelled: `#{err.word}`",
            "Suggestions: #{err.suggestions.first(5).map(&:word).join(', ')}"
          ]
        }
      end

      def word_at(text, offset)
        return "" if offset >= text.length || offset.negative?

        start = offset
        start -= 1 while start > 0 && word_char?(text[start - 1])
        finish = offset
        finish += 1 while finish < text.length && word_char?(text[finish])
        text[start...finish]
      end

      def word_char?(char)
        char =~ /[A-Za-z']/
      end

      def offset_for_position(text, line, character)
        line_starts = [0]
        text.each_char.with_index do |c, i|
          line_starts << (i + 1) if c == "\n"
        end
        return nil unless line < line_starts.size

        line_starts[line] + character
      end

      def language_id_for(uri, language_id)
        return language_id if language_id && language_id != "plaintext"

        ext = File.extname(uri || "").delete_prefix(".").downcase
        EXTENSION_TO_LANG.fetch(ext, nil) || "en"
      end

      EXTENSION_TO_LANG = {
        "md" => "en", "markdown" => "en", "txt" => "en",
        "asciidoc" => "en", "adoc" => "en", "ad" => "en",
        "rb" => "en", "py" => "en", "js" => "en", "ts" => "en",
        "go" => "en", "rs" => "en", "java" => "en"
      }.freeze

      def read_message
        headers = read_headers
        return nil if headers.empty?

        content_length = headers["content-length"].to_i
        return nil if content_length.zero?

        body = @input.read(content_length)
        return nil unless body

        JSON.parse(body)
      rescue JSON::ParserError => e
        @logger.error("malformed JSON message: #{e.message}")
        retry
      end

      def read_headers
        headers = {}
        loop do
          line = @input.gets
          return headers if line.nil?
          line = line.chomp
          break if line.empty?

          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip if value
        end
        headers
      end

      def respond(id, result)
        return unless id

        send_message({ jsonrpc: "2.0", id: id, result: result })
      end

      def respond_error(id, code, message)
        send_message({ jsonrpc: "2.0", id: id, error: { code: code, message: message } })
      end

      def send_notification(method, params)
        send_message({ jsonrpc: "2.0", method: method, params: params })
      end

      def send_message(hash)
        payload = JSON.generate(hash)
        header = "Content-Length: #{payload.bytesize}\r\n\r\n"
        @output_mutex.synchronize do
          @output.write(header)
          @output.write(payload)
          @output.flush
        end
      end

      def log(level, message)
        @logger.public_send(level, message)
      end
    end
  end
end
