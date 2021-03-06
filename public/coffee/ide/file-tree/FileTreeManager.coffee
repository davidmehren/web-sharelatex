define [
	"ide/file-tree/directives/fileEntity"
	"ide/file-tree/directives/draggable"
	"ide/file-tree/directives/droppable"
	"ide/file-tree/controllers/FileTreeController"
	"ide/file-tree/controllers/FileTreeEntityController"
	"ide/file-tree/controllers/FileTreeFolderController"
	"ide/file-tree/controllers/FileTreeRootFolderController"
], () ->
	class FileTreeManager
		constructor: (@ide, @$scope) ->
			@$scope.$on "project:joined", =>
				@loadRootFolder()
				@loadDeletedDocs()
				@$scope.$emit "file-tree:initialized"

			@$scope.$watch "rootFolder", (rootFolder) =>
				if rootFolder?
					@recalculateDocList()

			@_bindToSocketEvents()

			@$scope.multiSelectedCount = 0

			$(document).on "click", =>
				@clearMultiSelectedEntities()
				@$scope.$digest()

		_bindToSocketEvents: () ->
			@ide.socket.on "reciveNewDoc", (parent_folder_id, doc) =>
				parent_folder = @findEntityById(parent_folder_id) or @$scope.rootFolder
				@$scope.$apply () =>
					parent_folder.children.push {
						name: doc.name
						id:   doc._id
						type: "doc"
					}
					@recalculateDocList()

			@ide.socket.on "reciveNewFile", (parent_folder_id, file, source, linkedFileData) =>
				parent_folder = @findEntityById(parent_folder_id) or @$scope.rootFolder
				@$scope.$apply () =>
					parent_folder.children.push {
						name: file.name
						id:   file._id
						type: "file",
						linkedFileData: linkedFileData
					}
					@recalculateDocList()

			@ide.socket.on "reciveNewFolder", (parent_folder_id, folder) =>
				parent_folder = @findEntityById(parent_folder_id) or @$scope.rootFolder
				@$scope.$apply () =>
					parent_folder.children.push {
						name: folder.name
						id:   folder._id
						type: "folder"
						children: []
					}
					@recalculateDocList()

			@ide.socket.on "reciveEntityRename", (entity_id, name) =>
				entity = @findEntityById(entity_id)
				return if !entity?
				@$scope.$apply () =>
					entity.name = name
					@recalculateDocList()

			@ide.socket.on "removeEntity", (entity_id) =>
				entity = @findEntityById(entity_id)
				return if !entity?
				@$scope.$apply () =>
					@_deleteEntityFromScope entity
					@recalculateDocList()
				@$scope.$broadcast "entity:deleted", entity

			@ide.socket.on "reciveEntityMove", (entity_id, folder_id) =>
				entity = @findEntityById(entity_id)
				folder = @findEntityById(folder_id)
				@$scope.$apply () =>
					@_moveEntityInScope(entity, folder)
					@recalculateDocList()

		selectEntity: (entity) ->
			@selected_entity_id = entity.id # For reselecting after a reconnect
			@ide.fileTreeManager.forEachEntity (entity) ->
				entity.selected = false
			entity.selected = true

		toggleMultiSelectEntity: (entity) ->
			entity.multiSelected = !entity.multiSelected
			@$scope.multiSelectedCount = @multiSelectedCount()

		multiSelectedCount: () ->
			count = 0
			@forEachEntity (entity) ->
				if entity.multiSelected
					count++
			return count

		getMultiSelectedEntities: () ->
			entities = []
			@forEachEntity (e) ->
				if e.multiSelected
					entities.push e
			return entities

		getMultiSelectedEntityChildNodes: () ->
			entities = @getMultiSelectedEntities()
			paths = {}
			for entity in entities
				paths[@getEntityPath(entity)] = entity
			prefixes = {}
			for path, entity of paths
				parts = path.split("/")
				if parts.length <= 1
					continue
				else
					# Record prefixes a/b/c.tex -> 'a' and 'a/b'
					for i in [1..(parts.length - 1)]
						prefixes[parts.slice(0,i).join("/")] = true
			child_entities = []
			for path, entity of paths
				# If the path is in the prefixes, then it's a parent folder and
				# should be ignore
				if !prefixes[path]?
					child_entities.push entity
			return child_entities

		clearMultiSelectedEntities: () ->
			return if @$scope.multiSelectedCount == 0 # Be efficient, this is called a lot on 'click'
			@forEachEntity (entity) ->
				entity.multiSelected = false
			@$scope.multiSelectedCount = 0

		multiSelectSelectedEntity: () ->
			@findSelectedEntity()?.multiSelected = true

		existsInFolder: (folder_id, name) ->
			folder = @findEntityById(folder_id)
			return false if !folder?
			entity = @_findEntityByPathInFolder(folder, name)
			return entity?

		findSelectedEntity: () ->
			selected = null
			@forEachEntity (entity) ->
				selected = entity if entity.selected
			return selected

		findEntityById: (id, options = {}) ->
			return @$scope.rootFolder if @$scope.rootFolder.id == id

			entity = @_findEntityByIdInFolder @$scope.rootFolder, id
			return entity if entity?

			if options.includeDeleted
				for entity in @$scope.deletedDocs
					return entity if entity.id == id

			return null

		_findEntityByIdInFolder: (folder, id) ->
			for entity in folder.children or []
				if entity.id == id
					return entity
				else if entity.children?
					result = @_findEntityByIdInFolder(entity, id)
					return result if result?

			return null

		findEntityByPath: (path) ->
			@_findEntityByPathInFolder @$scope.rootFolder, path

		_findEntityByPathInFolder: (folder, path) ->
			if !path? or !folder?
				return null
			if path == ""
				return folder

			parts = path.split("/")
			name = parts.shift()
			rest = parts.join("/")

			if name == "."
				return @_findEntityByPathInFolder(folder, rest)

			for entity in folder.children
				if entity.name == name
					if rest == ""
						return entity
					else if entity.type == "folder"
						return @_findEntityByPathInFolder(entity, rest)
			return null

		forEachEntity: (callback = (entity, parent_folder, path) ->) ->
			@_forEachEntityInFolder(@$scope.rootFolder, null, callback)

			for entity in @$scope.deletedDocs or []
				callback(entity)

		_forEachEntityInFolder: (folder, path, callback) ->
			for entity in folder.children or []
				if path?
					childPath = path + "/" + entity.name
				else
					childPath = entity.name
				callback(entity, folder, childPath)
				if entity.children?
					@_forEachEntityInFolder(entity, childPath, callback)

		getEntityPath: (entity) ->
			@_getEntityPathInFolder @$scope.rootFolder, entity

		_getEntityPathInFolder: (folder, entity) ->
			for child in folder.children or []
				if child == entity
					return entity.name
				else if child.type == "folder"
					path = @_getEntityPathInFolder(child, entity)
					if path?
						return child.name + "/" + path
			return null

		getRootDocDirname: () ->
			rootDoc = @findEntityById @$scope.project.rootDoc_id
			return if !rootDoc?
			return @_getEntityDirname(rootDoc)

		_getEntityDirname: (entity) ->
			path = @getEntityPath(entity)
			return if !path?
			return path.split("/").slice(0, -1).join("/")

		_findParentFolder: (entity) ->
			dirname = @_getEntityDirname(entity)
			return if !dirname?
			return @findEntityByPath(dirname)

		loadRootFolder: () ->
			@$scope.rootFolder = @_parseFolder(@$scope?.project?.rootFolder[0])

		_parseFolder: (rawFolder) ->
			folder = {
				name: rawFolder.name
				id:   rawFolder._id
				type: "folder"
				children: []
				selected: (rawFolder._id == @selected_entity_id)
			}

			for doc in rawFolder.docs or []
				folder.children.push {
					name: doc.name
					id:   doc._id
					type: "doc"
					selected: (doc._id == @selected_entity_id)
				}

			for file in rawFolder.fileRefs or []
				folder.children.push {
					name: file.name
					id:   file._id
					type: "file"
					selected: (file._id == @selected_entity_id)
					linkedFileData: file.linkedFileData
					created: file.created
				}

			for childFolder in rawFolder.folders or []
				folder.children.push @_parseFolder(childFolder)

			return folder

		loadDeletedDocs: () ->
			@$scope.deletedDocs = []
			for doc in @$scope.project.deletedDocs or []
				@$scope.deletedDocs.push {
					name: doc.name
					id:   doc._id
					type: "doc"
					deleted: true
				}

		recalculateDocList: () ->
			@$scope.docs = []
			@forEachEntity (entity, parentFolder, path) =>
				if entity.type == "doc" and !entity.deleted
					@$scope.docs.push {
						doc:  entity
						path: path
					}
			# Keep list ordered by folders, then name
			@$scope.docs.sort (a,b) ->
				aDepth = (a.path.match(/\//g) || []).length
				bDepth = (b.path.match(/\//g) || []).length
				if aDepth - bDepth != 0
					return -(aDepth - bDepth) # Deeper path == folder first
				else if a.path < b.path
					return -1
				else
					return 1

		getEntityPath: (entity) ->
			@_getEntityPathInFolder @$scope.rootFolder, entity

		_getEntityPathInFolder: (folder, entity) ->
			for child in folder.children or []
				if child == entity
					return entity.name
				else if child.type == "folder"
					path = @_getEntityPathInFolder(child, entity)
					if path?
						return child.name + "/" + path
			return null

		getCurrentFolder: () ->
			# Return the root folder if nothing is selected
			@_getCurrentFolder(@$scope.rootFolder) or @$scope.rootFolder

		_getCurrentFolder: (startFolder = @$scope.rootFolder) ->
			for entity in startFolder.children or []
				# The 'current' folder is either the one selected, or
				# the one containing the selected doc/file
				if entity.selected
					if entity.type == "folder"
						return entity
					else
						return startFolder

				if entity.type == "folder"
					result = @_getCurrentFolder(entity)
					return result if result?

			return null

		projectContainsFolder: () ->
			for entity in @$scope.rootFolder.children
				return true if entity.type == 'folder'
			return false

		existsInThisFolder: (folder, name) ->
			for entity in folder?.children or []
				return true if entity.name is name
			return false

		nameExistsError: (message = "already exists") ->
			nameExists = @ide.$q.defer()
			nameExists.reject({data: message})
			return nameExists.promise

		createDoc: (name, parent_folder = @getCurrentFolder()) ->
			# check if a doc/file/folder already exists with this name
			if @existsInThisFolder parent_folder, name
				return @nameExistsError()
			# We'll wait for the socket.io notification to actually
			# add the doc for us.
			@ide.$http.post "/project/#{@ide.project_id}/doc", {
				name: name,
				parent_folder_id: parent_folder?.id
				_csrf: window.csrfToken
			}

		createFolder: (name, parent_folder = @getCurrentFolder()) ->
			# check if a doc/file/folder already exists with this name
			if @existsInThisFolder parent_folder, name
				return @nameExistsError()
			# We'll wait for the socket.io notification to actually
			# add the folder for us.
			return @ide.$http.post "/project/#{@ide.project_id}/folder", {
				name: name,
				parent_folder_id: parent_folder?.id
				_csrf: window.csrfToken
			}

		createLinkedFile: (name, parent_folder = @getCurrentFolder(), provider, data) ->
			# check if a doc/file/folder already exists with this name
			if @existsInThisFolder parent_folder, name
				return @nameExistsError()
			# We'll wait for the socket.io notification to actually
			# add the file for us.
			return @ide.$http.post "/project/#{@ide.project_id}/linked_file", {
				name: name,
				parent_folder_id: parent_folder?.id
				provider,
				data,
				_csrf: window.csrfToken
			}

		refreshLinkedFile: (file) ->
			parent_folder = @_findParentFolder(file)
			provider = file.linkedFileData?.provider
			if !provider?
				console.warn ">> no provider for #{file.name}", file
				return
			return @ide.$http.post "/project/#{@ide.project_id}/linked_file/#{file.id}/refresh", {
				_csrf: window.csrfToken
			}

		renameEntity: (entity, name, callback = (error) ->) ->
			return if entity.name == name
			return if name.length >= 150
			# check if a doc/file/folder already exists with this name
			parent_folder = @getCurrentFolder()
			if @existsInThisFolder parent_folder, name
				return @nameExistsError()
			entity.renamingToName = name
			@ide.$http.post("/project/#{@ide.project_id}/#{entity.type}/#{entity.id}/rename", {
				name: name,
				_csrf: window.csrfToken
			})
				.then () ->
					entity.name = name
				.finally () ->
					entity.renamingToName = null

		deleteEntity: (entity, callback = (error) ->) ->
			# We'll wait for the socket.io notification to
			# delete from scope.
			return @ide.queuedHttp {
				method: "DELETE"
				url:    "/project/#{@ide.project_id}/#{entity.type}/#{entity.id}"
				headers:
					"X-Csrf-Token": window.csrfToken
			}

		moveEntity: (entity, parent_folder, callback = (error) ->) ->
			# Abort move if the folder being moved (entity) has the parent_folder as child
			# since that would break the tree structure.
			return if @_isChildFolder(entity, parent_folder)
			# check if a doc/file/folder already exists with this name
			if @existsInThisFolder parent_folder, entity.name
				return @nameExistsError()
			# Wait for the http response before doing the move
			@ide.queuedHttp.post("/project/#{@ide.project_id}/#{entity.type}/#{entity.id}/move", {
				folder_id: parent_folder.id
				_csrf: window.csrfToken
			}).then () =>
				@_moveEntityInScope(entity, parent_folder)

		_isChildFolder: (parent_folder, child_folder) ->
			parent_path = @getEntityPath(parent_folder) or "" # null if root folder
			child_path = @getEntityPath(child_folder) or "" # null if root folder
			# is parent path the beginning of child path?
			return (child_path.slice(0, parent_path.length) == parent_path)

		_deleteEntityFromScope: (entity, options = { moveToDeleted: true }) ->
			return if !entity?
			parent_folder = null
			@forEachEntity (possible_entity, folder) ->
				if possible_entity == entity
					parent_folder = folder

			if parent_folder?
				index = parent_folder.children.indexOf(entity)
				if index > -1
					parent_folder.children.splice(index, 1)

			if entity.type == "doc" and options.moveToDeleted
				entity.deleted = true
				@$scope.deletedDocs.push entity

		_moveEntityInScope: (entity, parent_folder) ->
			return if entity in parent_folder.children
			@_deleteEntityFromScope(entity, moveToDeleted: false)
			parent_folder.children.push(entity)
