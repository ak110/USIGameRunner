#!/usr/bin/ruby
# -*- encoding: utf-8 -*-

if ARGV.length != 2 then
	puts 'usage: USIGameRunner.rb engine1 engine2'
	exit 1
end

# USIエンジンの指定
$engine1_path = File.expand_path(ARGV[0])
$engine2_path = File.expand_path(ARGV[1])

# 思考に使うUSIコマンド（持ち時間の計測などはしていないため、基本的にbyoyomiを指定するだけ）
$go_command = 'go btime 0 wtime 0 byoyomi 1000'

# 終局時に改行区切りで棋譜を追記するファイル
$sfen_file_path = './games.sfen'

# 対局結果を記録するログファイル
# 例："投了: 1-0-3/4" と出力されている場合、
#     最後の対局がどちらかの投了で終わっていて、
#     engine1の通算1勝3敗0引き分け。
$log_file_path = './games.log'

################################################################################

require 'logger'
require 'thread'
require 'open3'

class USIEngine
    attr_accessor :name, :engine_path, :exited

    # エンジンを起動
    def initialize(name, engine_path)
        @name = name
        @engine_path = engine_path
        @stdin, @stdout, @stderr, @wait_thr = *Open3.popen3(
            @engine_path, :chdir => File.dirname(@engine_path))
        @queue = Queue.new
        Thread.fork {
            @stdout.each do |line|
                print @name + '> ' + line
                @queue.push line.chomp
            end
            @queue.push 'quit' # 念のため…
            @exited = true
        }
        Thread.fork {
            @stderr.each do |line|
                print @name + '> ' + line
            end
        }
        # いきなりusi/isreadyを送りつける
        send 'usi'
        send 'isready'
    end

    def send(command)
        puts @name + '< ' + command
        @stdin.puts command
        @stdin.flush # 無くても動いていたけど一応
    end

    def wait_for(command)
        while !@exited
            line = @queue.pop
            break if line == command
        end
    end

    def wait_for_bestmove()
        while !@exited
            line = @queue.pop
            return line[9 .. line.length].strip if line.start_with?('bestmove ')
        end
        return nil
    end
end

class GameRunner
    def initialize()
        @logger = Logger.new($log_file_path)
        @engines = [
            USIEngine.new('engine1', $engine1_path),
            USIEngine.new('engine2', $engine2_path),
        ]
        @engines[0].wait_for 'readyok'
        @engines[1].wait_for 'readyok'
        @counts = [ 0, 0, 0 ] # engine1の勝ち数、engine2の勝ち数、引き分け数
    end

    # 連続対局
    def run()
        side_to_first_move = rand(2)
        while !@engines[0].exited && !@engines[1].exited
            do_game side_to_first_move
            side_to_first_move ^= 1
        end
    end

    private
    # 対局を1回実行する
    def do_game(side_to_first_move)
        @engines[0].send 'usinewgame'
        @engines[1].send 'usinewgame'

        sfen = 'position startpos'
        side_to_move = side_to_first_move
        move_count = 0
        while true
            @engines[side_to_move].send sfen
            @engines[side_to_move].send $go_command
            move = @engines[side_to_move].wait_for_bestmove
            break if move == nil # エンジンが落ちた？ → 自己対戦的には意味が無いのでカウントせず終了する

            # 投了
            if move == 'resign' then
                on_gameover side_to_move ^ 1, '投了'
                break
            end

            sfen += ' moves' if sfen == 'position startpos' # 最初だけ必要になってしまう…
            sfen += ' ' + move
            side_to_move ^= 1
            move_count += 1

            # 256手ルールと千日手判定
            if 256 <= move_count || is_repetition(sfen) then
                on_gameover 2, 256 <= move_count ? '256手超過' : '千日手'
                break
            end
        end

        # 棋譜を記録
        File.open($sfen_file_path, 'a') do |file|
            file.puts sfen
        end
    end

    # 千日手判定（適当）
    def is_repetition(sfen)
        # SFEN文字列中の末尾の15文字くらいが4回出現していたら千日手扱いにしてしまう
        return false if sfen.length <= 50 # 短い時はまだやらない（適当）
        check = sfen[sfen.length - 5 * 3, sfen.length]
        ix = -1
        for i in 0..3 do
            ix = sfen.index(check, ix + 1)
            return false if ix == nil
        end
        return true
    end

    # 終局時の処理
    def on_gameover(winner, result)
        @counts[winner] += 1
        if winner == 2 then
            @engines[0].send 'gameover draw'
            @engines[1].send 'gameover draw'
        else
            @engines[winner ^ 0].send 'gameover win'
            @engines[winner ^ 1].send 'gameover lose'
        end
        display_counts = @counts[0].to_s + '-' + @counts[2].to_s + '-' + @counts[1].to_s + '/' + @counts.inject(:+).to_s
        @logger.info result + ': ' + display_counts
    end
end

runner = GameRunner.new
runner.run

# vim: set expandtab tabstop=4 :
