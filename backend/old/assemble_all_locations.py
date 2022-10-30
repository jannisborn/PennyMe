import os
import json
import glob

# Assemble a single json with locations of all machines.
locations = []
with open('../data/all_locations.json', 'a', encoding='utf8') as target_file:
    
    # Loop over all jsons that we have 
    for country_folder, _, _ in os.walk('../data/countries/'):
        for file in glob.glob(country_folder+'/data.json'):
            with open(file, 'r') as source_file:
                print(file)
                txt = json.load(source_file, encoding='utf8')
                txt = txt['data']
                locations.extend(txt)
                
    data = {'data': locations}
    json.dump(data, target_file, ensure_ascii=False, indent=4)