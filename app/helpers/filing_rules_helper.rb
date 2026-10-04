module FilingRulesHelper
  # What a form's "sweep" box is read from: whether it's ticked. The box isn't an attribute of anything that's saved, so a form that has
  # one builds its field from this.
  SweepChoice = Data.define(:sweep)
end
