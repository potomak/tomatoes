require 'mongoid_tags'
require 'csv'

class Tomato
  include Mongoid::Document
  include Mongoid::Document::Taggable
  include Mongoid::Timestamps
  include Chartable

  belongs_to :user

  index(created_at: 1)

  validate :must_not_overlap, on: :create
  after_create :score_on_leaderboard

  DURATION       = Rails.env.development? ? 25 : 25 * 60 # pomodoro default duration in seconds
  BREAK_DURATION = Rails.env.development? ? 5  : 5 * 60  # pomodoro default break duration in seconds

  include ActionView::Helpers::TextHelper
  include ApplicationHelper

  class << self
    def after(time)
      where(created_at: { '$gte': time }).order_by([[:created_at, :desc]])
    end

    def ranking_map
      %{ function() { emit(this.user_id, 1); } }
    end

    def ranking_reduce
      %{ function(key, values) { return Array.sum( values ); } }
    end

    def time_period_scope(time_period)
      if :all_time != time_period
        where(:created_at.gt => Time.current.send(beginning_of(time_period)))
      else
        all
      end
    end

    def time_period_map_reduce(time_period = 'today')
      time_period_scope(time_period).map_reduce(ranking_map, ranking_reduce)
    end

    def ranking_collection(time_period)
      time_period_map_reduce(time_period)
        .out(replace: "user_ranking_#{time_period}s")
    end

    def by_day(tomatoes)
      to_lines(tomatoes) do |tomatoes_by_day|
        yield(tomatoes_by_day)
      end
    end

    def by_hour(tomatoes)
      to_hours_bars(tomatoes) do |tomatoes_by_hour|
        yield(tomatoes_by_hour)
      end
    end

    def by_tags(tomatoes)
      tomatoes
        .map(&:tags)
        .flatten
        .group_by(&:itself)
        .map { |tag, tags| [tag, tags.size] }
        .sort { |a, b| b[1] <=> a[1] }
    end

    # CSV representation.
    def to_csv(tomatoes, opts = {})
      CSV.generate(opts) do |csv|
        tomatoes.each do |tomato|
          csv << [tomato.created_at, tomato.tags.join(', ')]
        end
      end
    end

    private

    def beginning_of(time_period)
      case time_period
      when :today
        'beginning_of_day'
      when :this_week
        'beginning_of_week'
      when :this_month
        'beginning_of_month'
      end
    end
  end

  def projects
    user.projects.tagged_with(tags)
  end

  private

  def must_not_overlap
    last_tomato = user.tomatoes.after(Time.zone.now - DURATION.seconds).first
    if last_tomato
      limit = (DURATION.seconds - (Time.zone.now - last_tomato.created_at)).seconds
      errors.add(:base, "Must not overlap saved tomaotes, please wait #{humanize(limit)}")
    end
  end

  def score_on_leaderboard
    ScoreOnLeaderboardJob.perform_async(self.user._id)
  end
end
