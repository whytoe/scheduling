# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Scheduling.Repo.insert!(%Scheduling.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

import Ecto.Query

alias Scheduling.Repo
alias Scheduling.Catalog.{Capability, Diagnosis}

# Capability catalog. Idempotent: upsert by unique name.
# "Lab" was previously here but was too coarse — broken into "Blood Draw" and
# "Urinalysis". The catalog UI at /capabilities lets staff add more.
capability_names = [
  "XRay",
  "Computed Tomography (CT)",
  "Magnetic Resonance Imaging (MRI)",
  "Ultrasound",
  "Mammography",
  "Electrocardiogram (EKG)",
  "Echocardiogram",
  "Stress Test",
  "Pulmonary Function Test",
  "Endoscopy",
  "Dialysis",
  "Blood Draw",
  "Urinalysis",
  "Intravenous Infusion (IV)"
]

for name <- capability_names do
  Repo.insert!(
    %Capability{name: name},
    on_conflict: :nothing,
    conflict_target: :name
  )
end

capabilities =
  from(c in Capability, where: c.name in ^capability_names)
  |> Repo.all()
  |> Map.new(fn c -> {c.name, c} end)

# Example Diagnosis -> default required capabilities mappings.
diagnosis_defaults = [
  {"Fractured Wrist", "DX-FRAC", ["XRay"]},
  {"Stroke Workup", "DX-STRK", ["Computed Tomography (CT)", "Blood Draw"]},
  {"Abdominal Pain", "DX-ABDP", ["Ultrasound", "Blood Draw"]}
]

for {name, code, required} <- diagnosis_defaults do
  diagnosis =
    case Repo.get_by(Diagnosis, name: name) do
      nil -> Repo.insert!(%Diagnosis{name: name, code: code})
      existing -> existing
    end

  required_caps = Enum.map(required, &Map.fetch!(capabilities, &1))

  diagnosis
  |> Repo.preload(:capabilities)
  |> Ecto.Changeset.change()
  |> Ecto.Changeset.put_assoc(:capabilities, required_caps)
  |> Repo.update!()
end
