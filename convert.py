

from rasa.nlu.convert import convert_training_data
input_training_file = '/home/emilio/wilson/data/nlu.json'
output_md_file = '/home/emilio/wilson/data/nlu.md'


convert_training_data(data_file=input_training_file, out_file=output_md_file , output_format="md", language="")

