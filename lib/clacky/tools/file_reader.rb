# frozen_string_literal: true

require_relative "base"
require "base64"

module Clacky
  module Tools
    class FileReader < Base
      self.tool_name = "file_reader"
      self.tool_description = "Read contents of a file from the filesystem"
      self.tool_category = "file_system"
      self.tool_parameters = {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Absolute or relative path to the file"
          },
          max_lines: {
            type: "integer",
            description: "Maximum number of lines to read (optional)",
            default: 1000
          }
        },
        required: ["path"]
      }
      
      # Supported binary formats that can be sent to LLM
      # Images: PNG, JPEG, GIF, WebP
      # Documents: PDF
      LLM_COMPATIBLE_FORMATS = %w[.png .jpg .jpeg .gif .webp .pdf].freeze
      
      # Binary file signatures (magic bytes) for detection
      BINARY_SIGNATURES = {
        png: "\x89PNG".b,
        jpeg: "\xFF\xD8\xFF".b,
        gif_87: "GIF87a".b,
        gif_89: "GIF89a".b,
        pdf: "%PDF".b,
        webp_riff: "RIFF".b  # WebP starts with RIFF, followed by WEBP at offset 8
      }.freeze

      def execute(path:, max_lines: 1000)
        # Expand ~ to home directory
        expanded_path = File.expand_path(path)
        
        unless File.exist?(expanded_path)
          return {
            path: expanded_path,
            content: nil,
            error: "File not found: #{expanded_path}"
          }
        end

        # If path is a directory, list its first-level contents (similar to filetree)
        if File.directory?(expanded_path)
          return list_directory_contents(expanded_path)
        end

        unless File.file?(expanded_path)
          return {
            path: expanded_path,
            content: nil,
            error: "Path is not a file: #{expanded_path}"
          }
        end

        begin
          # Check if file is binary
          if binary_file?(expanded_path)
            return handle_binary_file(expanded_path)
          end
          
          # Read text file
          lines = File.readlines(expanded_path).first(max_lines)
          content = lines.join
          truncated = File.readlines(expanded_path).size > max_lines

          {
            path: expanded_path,
            content: content,
            lines_read: lines.size,
            truncated: truncated,
            error: nil
          }
        rescue StandardError => e
          {
            path: expanded_path,
            content: nil,
            error: "Error reading file: #{e.message}"
          }
        end
      end

      def format_call(args)
        path = args[:path] || args['path']
        "Read(#{Utils::PathHelper.safe_basename(path)})"
      end

      def format_result(result)
        return result[:error] if result[:error]

        # Handle directory listing
        if result[:is_directory] || result['is_directory']
          entries = result[:entries_count] || result['entries_count'] || 0
          dirs = result[:directories_count] || result['directories_count'] || 0
          files = result[:files_count] || result['files_count'] || 0
          return "Listed #{entries} entries (#{dirs} directories, #{files} files)"
        end

        # Handle binary file
        if result[:binary] || result['binary']
          format_type = result[:format] || result['format'] || 'unknown'
          size = result[:size_bytes] || result['size_bytes'] || 0
          
          # Check if it has base64 data (LLM-compatible format)
          if result[:base64_data] || result['base64_data']
            size_warning = size > 5_000_000 ? " (WARNING: large file)" : ""
            return "Binary file (#{format_type}, #{format_file_size(size)}) - sent to LLM#{size_warning}"
          else
            return "Binary file (#{format_type}, #{format_file_size(size)}) - cannot be read as text"
          end
        end

        # Handle text file reading
        lines = result[:lines_read] || result['lines_read'] || 0
        truncated = result[:truncated] || result['truncated']
        "Read #{lines} lines#{truncated ? ' (truncated)' : ''}"
      end
      
      # Format result for LLM - handles both text and binary (image/PDF) content
      # This method is called by the agent to format tool results before sending to LLM
      def format_result_for_llm(result)
        # For LLM-compatible binary files with base64 data, return as content blocks
        if result[:binary] && result[:base64_data]
          # Create a text description
          description = "File: #{result[:path]}\nType: #{result[:format]}\nSize: #{format_file_size(result[:size_bytes])}"
          
          # Add size warning for large files
          if result[:size_bytes] > 5_000_000
            description += "\nWARNING: Large file (>5MB) - may consume significant tokens"
          end
          
          # For images, return both description and image content
          if result[:mime_type]&.start_with?("image/")
            return {
              type: "image",
              path: result[:path],
              format: result[:format],
              size_bytes: result[:size_bytes],
              mime_type: result[:mime_type],
              base64_data: result[:base64_data],
              description: description
            }
          end
          
          # For PDFs and other binary formats, just return metadata with base64
          return {
            type: "document",
            path: result[:path],
            format: result[:format],
            size_bytes: result[:size_bytes],
            mime_type: result[:mime_type],
            base64_data: result[:base64_data],
            description: description
          }
        end
        
        # For other cases, return the result as-is (agent will JSON.generate it)
        result
      end

      private def binary_file?(path)
        # Read first few bytes to check for binary signatures
        File.open(path, 'rb') do |file|
          header = file.read(12) || ""
          
          # Check for known binary signatures
          return true if header.start_with?(BINARY_SIGNATURES[:png])
          return true if header.start_with?(BINARY_SIGNATURES[:jpeg])
          return true if header.start_with?(BINARY_SIGNATURES[:gif_87])
          return true if header.start_with?(BINARY_SIGNATURES[:gif_89])
          return true if header.start_with?(BINARY_SIGNATURES[:pdf])
          
          # Check for WebP (RIFF....WEBP)
          if header.start_with?(BINARY_SIGNATURES[:webp_riff]) && header.length >= 12
            return true if header[8..11] == "WEBP".b
          end
          
          # Heuristic: check for null bytes or high ratio of non-printable characters
          # Read more bytes for better detection
          sample = header + (file.read(500) || "")
          return false if sample.empty?
          
          # Check for null bytes (common in binary files)
          return true if sample.include?("\x00")
          
          # Check ratio of printable characters
          printable_count = sample.chars.count { |c| c.ord >= 32 && c.ord < 127 || c == "\n" || c == "\r" || c == "\t" }
          ratio = printable_count.to_f / sample.length
          
          # If less than 70% printable, consider it binary
          ratio < 0.7
        end
      rescue StandardError
        # If we can't read the file, assume it's not binary
        false
      end
      
      private def handle_binary_file(path)
        ext = File.extname(path).downcase
        
        # Check if it's an LLM-compatible format
        if LLM_COMPATIBLE_FORMATS.include?(ext)
          # Read file as binary and encode to base64
          binary_data = File.binread(path)
          base64_data = Base64.strict_encode64(binary_data)
          
          # Detect MIME type
          mime_type = detect_mime_type(path, binary_data)
          
          {
            path: path,
            binary: true,
            format: ext[1..-1], # Remove the leading dot
            mime_type: mime_type,
            size_bytes: binary_data.length,
            base64_data: base64_data,
            error: nil
          }
        else
          # Binary file that we can't send to LLM
          file_size = File.size(path)
          {
            path: path,
            binary: true,
            format: ext.empty? ? "unknown" : ext[1..-1],
            size_bytes: file_size,
            content: nil,
            error: "Binary file detected. This format cannot be read as text. File size: #{format_file_size(file_size)}"
          }
        end
      end
      
      private def detect_mime_type(path, data)
        ext = File.extname(path).downcase
        
        case ext
        when ".png"
          "image/png"
        when ".jpg", ".jpeg"
          "image/jpeg"
        when ".gif"
          "image/gif"
        when ".webp"
          "image/webp"
        when ".pdf"
          "application/pdf"
        else
          # Try to detect from file signature
          if data.start_with?(BINARY_SIGNATURES[:png])
            "image/png"
          elsif data.start_with?(BINARY_SIGNATURES[:jpeg])
            "image/jpeg"
          elsif data.start_with?(BINARY_SIGNATURES[:gif_87]) || data.start_with?(BINARY_SIGNATURES[:gif_89])
            "image/gif"
          elsif data.start_with?(BINARY_SIGNATURES[:webp_riff]) && data.length >= 12 && data[8..11] == "WEBP".b
            "image/webp"
          elsif data.start_with?(BINARY_SIGNATURES[:pdf])
            "application/pdf"
          else
            "application/octet-stream"
          end
        end
      end
      
      private def format_file_size(bytes)
        if bytes < 1024
          "#{bytes} bytes"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(2)} KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(2)} MB"
        end
      end

      private

      # List first-level directory contents (files and directories)
      private def list_directory_contents(path)
        begin
          entries = Dir.entries(path).reject { |entry| entry == "." || entry == ".." }
          
          # Separate files and directories
          files = []
          directories = []
          
          entries.each do |entry|
            full_path = File.join(path, entry)
            if File.directory?(full_path)
              directories << entry + "/"
            else
              files << entry
            end
          end
          
          # Sort directories and files separately, then combine
          directories.sort!
          files.sort!
          all_entries = directories + files
          
          # Format as a tree-like structure
          content = all_entries.map { |entry| "  #{entry}" }.join("\n")
          
          {
            path: path,
            content: "Directory listing:\n#{content}",
            entries_count: all_entries.size,
            directories_count: directories.size,
            files_count: files.size,
            is_directory: true,
            error: nil
          }
        rescue StandardError => e
          {
            path: path,
            content: nil,
            error: "Error reading directory: #{e.message}"
          }
        end
      end
    end
  end
end
