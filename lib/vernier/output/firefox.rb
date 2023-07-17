# frozen_string_literal: true

require "json"

module Vernier
  module Output
    # https://profiler.firefox.com/
    # https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
    class Firefox
      class Categorizer
        attr_reader :categories
        def initialize
          @categories = []

          add_category(name: "Default", color: "grey")
          add_category(name: "GC", color: "red")
          add_category(
            name: "stdlib",
            color: "red",
            matcher: starts_with(RbConfig::CONFIG["rubylibdir"])
          )
          add_category(name: "cfunc", color: "yellow", matcher: "<cfunc>")

          rails_components = %w[ activesupport activemodel activerecord
          actionview actionpack activejob actionmailer actioncable
          activestorage actionmailbox actiontext railties ]
          add_category(
            name: "Rails",
            color: "green",
            matcher: gem_path(*rails_components)
          )
          add_category(
            name: "gem",
            color: "red",
            matcher: starts_with(*Gem.path)
          )
          add_category(
            name: "Application",
            color: "purple"
          )
        end

        def add_category(**kw)
          @categories << Category.new(@categories.length, **kw)
        end

        def starts_with(*paths)
          %r{\A#{Regexp.union(paths)}}
        end

        def gem_path(*names)
          %r{\A#{Regexp.union(Gem.path)}/gems/#{Regexp.union(names)}}
        end

        def categorize(path)
          @categories.detect { |category| category.matches?(path) } || @categories.first
        end

        class Category
          attr_reader :idx, :name, :color, :matcher
          def initialize(idx, name:, color:, matcher: nil)
            @idx = idx
            @name = name
            @color = color
            @matcher = matcher
          end

          def matches?(path)
            @matcher && @matcher === path
          end
        end
      end

      def initialize(profile)
        @profile = profile

        @categorizer = Categorizer.new

        names = profile.func_table.fetch(:name)
        filenames = profile.func_table.fetch(:filename)

        @strings = Hash.new { |h, k| h[k] = h.size }
        @func_names = names.map do |name|
          @strings[name]
        end
        @filenames = filenames.map do |filename|
          @strings[filename]
        end
        @categories = filenames.map do |filename|
          @categorizer.categorize(filename)
        end
      end

      def output
        ::JSON.generate(data)
      end

      private

      attr_reader :profile

      def data
        {
          meta: {
            interval: 1, # FIXME: memory vs wall
            startTime: (profile.timestamps&.min || 0) / 1_000_000.0,
            endTime: (profile.timestamps&.max || 0) / 1_000_000.0,
            processType: 0,
            product: "Ruby/Vernier",
            stackwalk: 1,
            version: 28,
            preprocessedProfileVersion: 47,
            symbolicated: true,
            markerSchema: [],
            sampleUnits: {
              time: "ms",
              eventDelay: "ms",
              threadCPUDelta: "µs"
            }, # FIXME: memory vs wall
            categories: @categorizer.categories.map do |category|
              {
                name: category.name,
                color: category.color,
                subcategories: []
              }
            end
          },
          libs: [],
          threads: [
            {
              name: "Main",
              isMainThread: true,
              processStartupTime: 0, # FIXME
              processShutdownTime: nil, # FIXME
              registerTime: 0,
              unregisterTime: nil,
              pausedRanges: [],
              pid: profile.pid,
              tid: 456,
              frameTable: frame_table,
              funcTable: func_table,
              nativeSymbols: {},
              stackTable: stack_table,
              samples: samples_table,
              resourceTable: {
                length: 0,
                lib: [],
                name: [],
                host: [],
                type: []
              },
              markers: markers_table,
              stringArray: string_table
            }
          ]
        }
      end

      def markers_table
        markers = profile.markers || []
        times = markers.map { _1 / 1_000_000.0 }
        size = times.size

        {
          data: [nil] * size,
          name: [@strings["test"]] * size,
          startTime: times,
          endTime: [nil] * size,
          phase: [0] * size,
          category: [0] * size,
          length: size
        }
      end

      def samples_table
        samples = profile.samples
        weights = profile.weights
        size = samples.size

        if profile.timestamps
          times = profile.timestamps.map { _1 / 1_000_000.0 }
        else
          # FIXME: record timestamps for memory samples
          times = (0...size).to_a
        end

        raise unless samples.size == size
        raise unless weights.size == size
        raise unless times.size == size

        {
          stack: samples,
          time: times,
          weight: weights,
          weightType: "samples",
          #weightType: "bytes",
          length: samples.length
        }
      end

      def stack_table
        frames = profile.stack_table.fetch(:frame)
        prefixes = profile.stack_table.fetch(:parent)
        size = frames.length
        raise unless frames.size == size
        raise unless prefixes.size == size
        {
          frame: frames,
          category: frames.map{|idx| @categories[idx].idx },
          subcategory: [0] * size,
          prefix: prefixes,
          length: prefixes.length
        }
      end

      def frame_table
        funcs = profile.frame_table.fetch(:func)
        lines = profile.frame_table.fetch(:line)
        size = funcs.length
        none = [nil] * size
        categories = @categories.map(&:idx)

        raise unless lines.size == funcs.size

        {
          address: [-1] * size,
          inlineDepth: [0] * size,
          category: categories,
          subcategory: nil,
          func: funcs,
          nativeSymbol: none,
          innerWindowID: none,
          implementation: none,
          line: lines,
          column: none,
          length: size
        }
      end

      def func_table
        size = @func_names.size

        cfunc_idx = @strings["<cfunc>"]
        is_js = @filenames.map { |fn| fn != cfunc_idx }
        {
          name: @func_names,
          isJS: is_js,
          relevantForJS: is_js,
          resource: [-1] * size, # set to unidentified for now
          fileName: @filenames,
          lineNumber: profile.func_table.fetch(:first_line),
          columnNumber: [0] * size,
          #columnNumber: functions.map { _1.column },
          length: size
        }
      end

      def string_table
        @strings.keys
      end
    end
  end
end
