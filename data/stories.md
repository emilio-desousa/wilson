## happy path
* salutation
  - utter_salutation
* trouver_conso
    - conso_form
    - form{"name": "conso_form"}
    - form{"name": null}
    - utter_slots_values

## sad path 1
* salutation
  - utter_salutation
* affirmatif
  - utter_happy

## sad path 2
* salutation
  - utter_salutation
* negatif
  - utter_adieu

## say adieu
* adieu
  - utter_adieu
