# PROTOTYPE (wayfinder ticket #90): throwaway helpers for the month view's Available bar variants. The real build puts
# this arithmetic on Budget::Month::EnvelopeLine, not in a helper.
module MonthPrototypeHelper
  A_LITTLE = Rational(1, 4)

  # What the envelope had to spend this month: Carried over + Assigned + Refunded + Reallocated in. Only the positive part of
  # Carried over (an Overspent envelope carries a negative) and of the net Reallocated count, so Available / this is never
  # over 100%.
  def had_to_spend(line)
    [ line.carried_over, 0 ].max + line.assigned + line.refunded + [ line.reallocated, 0 ].max
  end

  # :none (nothing to spend and no Spends), :overspent, :little or :plenty
  def available_level(line)
    return :overspent if line.available.negative?
    return :none if had_to_spend(line).zero? && line.spent.zero?
    return :plenty if had_to_spend(line).zero?
    line.available / had_to_spend(line) < A_LITTLE ? :little : :plenty
  end

  # 0..100, whole percent
  def available_percent(line)
    case available_level(line)
    when :overspent then 100
    when :none then 0
    else (line.available / had_to_spend(line) * 100).clamp(0, 100).round
    end
  end

  def level_word(level)
    { plenty: "Plenty", little: "A little", overspent: "Overspent" }[level]
  end

  def level_icon(level)
    { plenty: "✓", little: "!", overspent: "✕" }[level]
  end

  def level_bar_class(level)
    { plenty: "progress-success", little: "progress-warning", overspent: "progress-error" }[level]
  end

  def prototype_variant
    return unless Rails.env.development?
    params[:variant].to_s.upcase.presence_in(%w[ A B C ])
  end
end
