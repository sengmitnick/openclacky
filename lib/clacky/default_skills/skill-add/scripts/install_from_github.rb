#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'uri'
require 'find'

# Install skills from a GitHub repository
# Usage: ruby install_from_github.rb <github_url>
class SkillInstaller
  GITHUB_URL_PATTERNS = [
    %r{^https?://github\.com/[\w-]+/[\w.-]+(?:\.git)?$},
    %r{^git@github\.com:[\w-]+/[\w.-]+\.git$}
  ].freeze

  def initialize(repo_url, target_dir: nil)
    @repo_url = repo_url
    @target_dir = target_dir || File.join(Dir.pwd, '.clacky', 'skills')
    @installed_skills = []
    @errors = []
  end

  # Main installation process
  def install
    unless valid_github_url?
      raise ArgumentError, "Invalid GitHub URL: #{@repo_url}"
    end

    Dir.mktmpdir('clacky-skills-') do |tmpdir|
      clone_repository(tmpdir)
      discover_and_install_skills(tmpdir)
    end

    report_results
  rescue StandardError => e
    puts "❌ Installation failed: #{e.message}"
    exit 1
  end

  # Validate GitHub URL format
  private def valid_github_url?
    GITHUB_URL_PATTERNS.any? { |pattern| @repo_url.match?(pattern) }
  end

  # Clone the repository to temporary directory
  private def clone_repository(tmpdir)
    puts "📦 Cloning repository..."
    puts "   #{@repo_url}"
    
    clone_path = File.join(tmpdir, 'repo')
    
    # Use git clone with depth=1 for faster cloning
    system('git', 'clone', '--depth', '1', @repo_url, clone_path, 
           out: File::NULL, err: File::NULL)
    
    unless $?.success?
      raise "Failed to clone repository. Please check the URL and your network connection."
    end
    
    @clone_path = clone_path
  end

  # Discover all skills directories and install them
  private def discover_and_install_skills(tmpdir)
    skills_found = false
    
    # Search for any directory named 'skills' containing SKILL.md files
    Find.find(@clone_path) do |path|
      next unless File.directory?(path)
      next unless File.basename(path) == 'skills'
      
      # Check if this skills directory contains subdirectories with SKILL.md
      skill_dirs = Dir.glob(File.join(path, '*/SKILL.md')).map { |f| File.dirname(f) }
      
      next if skill_dirs.empty?
      
      skills_found = true
      install_skills_from_directory(path, skill_dirs)
    end
    
    unless skills_found
      raise "No skills found in repository. Looking for directories named 'skills/' containing SKILL.md files."
    end
  end

  # Install skills from a specific skills directory
  private def install_skills_from_directory(skills_dir, skill_dirs)
    skill_dirs.each do |skill_dir|
      skill_name = File.basename(skill_dir)
      target_path = File.join(@target_dir, skill_name)
      
      begin
        # Create target directory
        FileUtils.mkdir_p(@target_dir)
        
        # Check if skill already exists
        if File.exist?(target_path)
          puts "⚠️  Skill '#{skill_name}' already exists, skipping..."
          @errors << "Skill '#{skill_name}' already exists at #{target_path}"
          next
        end
        
        # Copy skill directory
        FileUtils.cp_r(skill_dir, target_path)
        
        # Read skill description from SKILL.md
        description = extract_description(File.join(target_path, 'SKILL.md'))
        
        @installed_skills << {
          name: skill_name,
          path: target_path,
          description: description
        }
        
      rescue StandardError => e
        @errors << "Failed to install '#{skill_name}': #{e.message}"
      end
    end
  end

  # Extract description from SKILL.md frontmatter
  private def extract_description(skill_file)
    return "No description" unless File.exist?(skill_file)
    
    content = File.read(skill_file)
    
    # Parse YAML frontmatter
    if content =~ /\A---\s*\n(.*?)\n---/m
      frontmatter = $1
      if frontmatter =~ /^description:\s*(.+)$/
        return $1.strip
      end
    end
    
    "No description"
  rescue StandardError
    "No description"
  end

  # Report installation results
  private def report_results
    puts "\n" + "=" * 60
    
    if @installed_skills.empty?
      puts "❌ No skills were installed."
      
      if @errors.any?
        puts "\nErrors encountered:"
        @errors.each { |err| puts "   • #{err}" }
      end
      
      exit 1
    end
    
    puts "✅ Installation complete!"
    puts "\nInstalled #{@installed_skills.size} skill(s):\n\n"
    
    @installed_skills.each do |skill|
      puts "   ✓ #{skill[:name]}"
      puts "     #{skill[:description]}"
      puts "     → #{skill[:path]}"
      puts
    end
    
    if @errors.any?
      puts "⚠️  Warnings:"
      @errors.each { |err| puts "   • #{err}" }
      puts
    end
    
    puts "You can now use these skills with /skill-name"
    puts "=" * 60
  end
end

# Run installer if called directly
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby install_from_github.rb <github_url>"
    puts "\nExamples:"
    puts "  ruby install_from_github.rb https://github.com/username/repo"
    puts "  ruby install_from_github.rb https://github.com/username/repo.git"
    exit 1
  end
  
  installer = SkillInstaller.new(ARGV[0])
  installer.install
end
