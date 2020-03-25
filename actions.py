# This files contains your custom actions which can be used to run
# custom Python code.
#
# See this guide on how to implement these action:
# https://rasa.com/docs/rasa/core/actions/#custom-actions/


# This is a simple example for a custom action which utters "Hello World!"

# from typing import Any, Text, Dict, List
#
# from rasa_sdk import Action, Tracker
# from rasa_sdk.executor import CollectingDispatcher
#
#
# class ActionHelloWorld(Action):
#
#     def name(self) -> Text:
#         return "action_hello_world"
#
#     def run(self, dispatcher: CollectingDispatcher,
#             tracker: Tracker,
#             domain: Dict[Text, Any]) -> List[Dict[Text, Any]]:
#
#         dispatcher.utter_message(text="Hello World!")
#
#         return []
from typing import Dict, Text, Any, List, Union, Optional

from rasa_sdk import Tracker
from rasa_sdk.executor import CollectingDispatcher
from rasa_sdk.forms import FormAction


class ConsoForm(FormAction):
    """Example of a custom form action"""

    def name(self) -> Text:
        """Unique identifier of the form"""

        return "conso_form"

    @staticmethod
    def required_slots(tracker: Tracker) -> List[Text]:
        """A list of required slots that the form has to fill"""

        return ["type_conso", "equipement", "nom_equipement",]

    def slot_mappings(self) -> Dict[Text, Union[Dict, List[Dict]]]:
        """A dictionary to map required slots to
            - an extracted entity
            - intent: value pairs
            - a whole message
            or a list of them, where a first match will be picked"""

        return {
            "type_conso": self.from_entity(entity="type_conso"),
            "equipement": self.from_entity(
                    entity="equipement", intent=["inform", "trouver_conso"]
                ),
            "nom_equipement": self.from_entity(entity="nom_equipement")
        }

    # USED FOR DOCS: do not rename without updating in docs
    @staticmethod
    def type_conso_db() -> List[Text]:
        """Database of supported type_conso"""

        return [
            "ram",
            "cpu",
            "stockage",
            "disque",
            "réseau"
        ]

    # USED FOR DOCS: do not rename without updating in docs
    @staticmethod
    def equipement_db() -> List[Text]:
        """Database of supported equipements"""

        return [
            "serveur",
            "firewall",
            "chassis",
            "application"
        ]

    @staticmethod
    def is_int(string: Text) -> bool:
        """Check if a string is an integer"""

        try:
            int(string)
            return True
        except ValueError:
            return False

    # USED FOR DOCS: do not rename without updating in docs
    def validate_type_conso(
        self,
        value: Text,
        dispatcher: CollectingDispatcher,
        tracker: Tracker,
        domain: Dict[Text, Any],
    ) -> Dict[Text, Any]:
        """Validate type_conso value."""
        
        if value.lower() == "appli":
            value = "application"
        if value.lower() in self.type_conso_db():
            # validation succeeded, set the value of the "type_conso" slot to value
            return {"type_conso": value}
        else:
            dispatcher.utter_message(template="utter_wrong_type_conso")
            # validation failed, set this slot to None, meaning the
            # user will be asked for the slot again
            return {"type_conso": None}

    def validate_equipement(
        self,
        value: Text,
        dispatcher: CollectingDispatcher,
        tracker: Tracker,
        domain: Dict[Text, Any],
    ) -> Dict[Text, Any]:
        """Validate equipement value."""

        if value.lower() in self.equipement_db():
            # validation succeeded, set the value of the "type_conso" slot to value
            return {"type_conso": value}
        else:
            dispatcher.utter_message(template="utter_wrong_equipement")
            # validation failed, set slot to None
            return {"equipement": None}

    def submit(
        self,
        dispatcher: CollectingDispatcher,
        tracker: Tracker,
        domain: Dict[Text, Any],
    ) -> List[Dict]:
        """Define what the form has to do
            after all required slots are filled"""

        # utter submit template
        dispatcher.utter_message(template="utter_submit")
        return []