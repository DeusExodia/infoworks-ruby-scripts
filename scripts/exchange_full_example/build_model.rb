# Create and run a model from raw data using Infoworks Exchange.
#
# * Import raw data using the ODIC
# * Exapand short links
# * Set elevations
# * Create controls
# * Create live data config
# * Create ddg
# * Validate model
# * Create run
# * Run simulation

require 'date'
require 'FileUtils'

script_path = File.dirname(__FILE__)
$LOAD_PATH.unshift script_path + '\lib'
load  script_path + '\lib\model_builder.rb'

prefix = Time.now.to_i.to_s
script_dir = File.dirname(WSApplication.script_file) 

db = WSApplication.open

puts "Creating model group"
model_group = db.new_model_object("Catchment Group", "ModelBuild_" + prefix )

puts "Creating network and import using ODIC"
moGeometry = model_group.new_model_object("Geometry", "Network_" + prefix)
moControl = model_group.new_model_object("Control", "Ctrl_" + prefix)
moLDC = model_group.new_model_object("Wesnet Live Data", "LDC_" + prefix)
moDDG = model_group.new_model_object("Demand Diagram Group", "DDG_" + prefix)

# Prompt user for a folder
shp_dir = script_path + '\source_data'
cfg_dir = script_path + '\cfg'
err_file = shp_dir + '\errors.txt'
script_file = cfg_dir + '\odic_script.bas'

layers = {
    "hydrant" => [{ "cfg" => cfg_dir + '\hydrant.cfg', "shp" => shp_dir + '\water_hydrant.shp'}],
    "fixedhead" => [{ "cfg" => cfg_dir + '\fixed_head.cfg', "shp" => shp_dir + '\water_treatment_works.shp'}],
    "valve" => [{ "cfg" => cfg_dir + '\valve.cfg', "shp" => shp_dir + '\water_valve.shp'}],
    "customerpoint" => [{ "cfg" => cfg_dir + '\customer.cfg', "shp" => shp_dir + '\addresses.shp'}],
    "meter" => [{ "cfg" => cfg_dir + '\meter.cfg', "shp" => shp_dir + '\water_meter.shp'}],
    #"polygons" => { "cfg" => cfg_dir + '\polygons.cfg',  "shp" => shp_dir + '\dma.shp' },
    "pipe" => [
        { "cfg" => cfg_dir + '\pipe.cfg', "shp" => shp_dir + '\water_mains_presplit.shp' },
        { "cfg" => cfg_dir + '\hydrant_lead.cfg', "shp" => shp_dir + '\water_hydrant_leads.shp'}
    ]
}

ModelBuilder::ODIC::import_data(moGeometry, layers, script_file, err_file)

moGeometry.commit "Import with ODIC"

open_network = moGeometry.open
ModelBuilder::ExpandLinks::run(open_network)
puts "Expanded Short Links"

moGeometry.commit "Expanded Short Links"

ModelBuilder::SetElevations::run(db, open_network)
puts "Set Elevation"

moGeometry.commit "Set Elevation"


open_control = moControl.open
ModelBuilder::SetControls::run(open_network, open_control)
puts "Set Controls"

moControl.commit "Set Controls"


live_data_folder = script_dir + '\source_data\scada'
open_ldc = moLDC.open
ModelBuilder::SetLiveData::run(open_network, open_ldc, live_data_folder)
puts "Set Live Data Config"

moLDC.commit "Set Live Data Config"


# Todo, make this dynamic
demand_diagram = script_dir + '\source_data\demand_diagram\Demand Diagram.ddg'
moDemandDiagram = moDDG.import_demand_diagram(demand_diagram)
puts "Importing Demand Diagram"

options = {
  "allocate_demand_unallocated" => true,
  "ignore_reservoirs" => true,
  "max_dist_along_pipe_native" => 500,
  "max_dist_to_pipe_native" => 500,
  "max_distance_steps" => 10,
  "max_pipe_diameter_native" => 500,
  "max_properties_per_node" => 200,
  "only_to_nearest_node" => false,
  "use_nearest_pipe" => true
}

puts "Running Demand Allocation (This may take a few minutes)"

DemandAllocation = WSDemandAllocation.new()
DemandAllocation.network = open_network
DemandAllocation.demand_diagram = moDemandDiagram
DemandAllocation.options = options 
DemandAllocation.allocate()

moGeometry.commit "Customer Demand Allocation"
puts "Demand Allocation Complete"

puts "Validating Network"
vals = open_network.validate
puts "Error count: #{vals.error_count}"
puts "Warning count: #{vals.warning_count}"


puts "Creating Simulation"
moRunGroup = model_group.new_model_object("Wesnet Run Group", "Runs")
run_group_id = moRunGroup.id

run_scheduler = WSRunScheduler.new()

run_options = {
  'ro_l_run_type' => 0,
  'ro_s_run_title' => 'Scripted Run',
  'ro_l_geometry_id' =>  moGeometry.id,
  'ro_l_demand_diagram_id' => moDemandDiagram.id,
  'ro_l_control_id' => moControl.id,
  'ro_dte_end_date_time' => DateTime.new(2020,1,2,0,0,0),
  'ro_dte_start_date_time' => DateTime.new(2020,1,1,0,0,0)
}

run_scheduler.create_new_run(run_group_id)
run_scheduler.set_parameters(run_options)

run_scheduler.validate(script_dir + '\validation_error.txt')
run_scheduler.save(false)


run = run_scheduler.get_run_mo()

puts "Starting simulation...."
run.run()

puts "Simulation Finished"
