extends VideoStreamPlayer
# Small script to make the video loop.

func _ready():
	self.finished.connect(_on_Finished)
	self.set_process(false)
	self.set_physics_process(false)

func _on_Finished():
	play()
