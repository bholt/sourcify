require 'ripper'

module Sourcify
  module Proc
    class Lexer19 < Ripper::Lexer #:nodoc:all

      include Lexer::Commons

      def on_nl(token)
        super.tap do |rs|
          raise EndOfLine unless @results.empty?
        end
      end

      alias_method :on_ignored_nl, :on_nl

      def on_kw(token)
        super.tap do |rs|
          next if @do_end_counter.started? && rs.curr.symbolized_keyword?
          send(:"on_kw_#{token}", rs) rescue NoMethodError
        end
      end

      def on_kw_class(rs)
        # Pretty straightforward for these, each of them will consume an 'end' close it
        @do_end_counter.increment_start if @do_end_counter.started?
      end

      # These work the same as 'class', the exception is 'for', which can have an optional
      # 'do' attached:
      # * for a in [1,2] do ... end
      # * for a in [1,2] \n ... end
      %w{def module begin case for}.each{|kw| alias_method :"on_kw_#{kw}", :on_kw_class }

      def on_kw_while(rs)
        # This has optional trailing 'do', and can work as a modifier as well, eg:
        # * while true do ... end # => 'do' must be on the same line as 'while'
        # * while true \n ... end
        # * ... while true # => 'while' is pre-pended with non-spaces
        if @do_end_counter.started? && (rs.start_of_line? or rs.within_block?)
          @do_end_counter.increment_start
        end
      end

      # These work exactly the same as 'while'.
      %w{until if unless}.each{|kw| alias_method :"on_kw_#{kw}", :on_kw_while }

      def on_kw_do(rs)
        if !@do_end_counter.started?
          rs.extend(Extensions) unless rs.respond_to?(:curr)
          @do_end_counter.marker = rs.curr
          @do_end_counter.increment_start
        elsif rs.same_as_curr_line.keywords(%w{for while until}).empty?
          # It is possible for a 'for', 'while' or 'until' to have an attached 'do',
          # for such a case, we want to skip it
          @do_end_counter.increment_start
        end
      end

      def on_kw_end(rs)
        if @do_end_counter.started? && @do_end_counter.increment_end.telly?
          @result = rs.to_code(@do_end_counter.marker)
          @is_multiline_block = rs.multiline?
          raise EndOfBlock
        end
      end

      def on_lbrace(token)
        super.tap do |rs|
          unless @do_end_counter.started?
            rs.extend(Extensions) unless rs.respond_to?(:curr)
            @braced_counter.marker = rs.curr unless @braced_counter.started?
            @braced_counter.increment_start
          end
        end
      end

      def on_rbrace(token)
        super.tap do |rs|
          if @braced_counter.started? && @braced_counter.increment_end.telly?
            @result = rs.to_code(@braced_counter.marker)
            @is_multiline_block = rs.multiline?
            raise EndOfBlock
          end
        end
      end

      def on_embexpr_beg(token)
        super.tap do |rs|
          @braced_counter.increment_start if @braced_counter.started?
        end
      end

      def on_op(token)
        super.tap do |rs|
          if @braced_counter.started? && token == '=>' && @braced_counter[:start] == 1
            @braced_counter.decrement_start
          end
        end
      end

      def on_label(token)
        super.tap do |rs|
          if @braced_counter.started? && @braced_counter[:start] == 1
            @braced_counter.decrement_start
          end
        end
      end

      # Ease working with the result set generated by Ripper
      module Extensions

        POS, TYP, VAL = 0, 1, 2
        ROW, COL= 0, 1

        def same_as_curr_line
          same_line(curr_line)
        end

        def multiline?
          self[0][POS][ROW] != self[-1][POS][ROW]
        end

        def curr_line
          curr[POS][ROW]
        end

        def curr
          (self[-1]).respond_to?(:symbolized_keyword?) ? self[-1] : (
            preceding, current = self[-2 .. -1]
            (class << current ; self ; end).class_eval do
              define_method(:symbolized_keyword?) do
                current[TYP] == :on_kw && preceding[TYP] == :on_symbeg
              end
            end
            current
          )
        end

        def same_line(line)
          (
            # ignore the current node
            self[0..-2].reverse.take_while do |e|
              if e[TYP] == :on_semicolon && e[VAL] == ';'
                false
              elsif e[POS][ROW] == line
                true
              elsif e[TYP] == :on_sp && e[VAL] == "\\\n"
                line -= 1
                true
              end
            end.reverse
          ).extend(Extensions)
        end

        def keywords(*types)
          (
            types = [types].flatten.map(&:to_s)
            select{|e| e[TYP] == :on_kw && (types.empty? or types.include?(e[VAL])) }
          ).extend(Extensions)
        end

        def non_spaces(*types)
          (
            types = [types].flatten
            reject{|e| e[TYP] == :on_sp && (types.empty? or types.include?(e[VAL])) }
          ).extend(Extensions)
        end

        def start_of_line?
          same_as_curr_line.non_spaces.empty?
        end

        def within_block?
          same_as_curr_line.non_spaces[-1][TYP] == :on_lparen
        end

        def to_code(marker)
          heredoc_beg = false # fixing mysteriously missing newline after :on_heredoc_begin
          self[index(marker) .. -1].map do |e|
            if e[TYP] == :on_heredoc_beg
              heredoc_beg = true
              e[VAL]
            elsif heredoc_beg && e[TYP] != :on_nl
              heredoc_beg = false
              "\n" + e[VAL]
            else
              heredoc_beg = false
              if e[TYP] == :on_label
                ':%s => ' % e[VAL][0..-2]
              elsif e[TYP] == :on_kw && e[VAL] == '__LINE__'
                e[POS][ROW]
              else
                e[VAL]
              end
            end
          end.join
        end

      end

    end
  end
end
