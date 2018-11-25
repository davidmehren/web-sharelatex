Project = require('../../models/Project').Project
settings = require "settings-sharelatex"
Doc = require('../../models/Doc').Doc
Folder = require('../../models/Folder').Folder
File = require('../../models/File').File
FileStoreHandler = require("../FileStore/FileStoreHandler")
Errors = require "../Errors/Errors"
tpdsUpdateSender = require('../ThirdPartyDataStore/TpdsUpdateSender')
projectLocator = require('./ProjectLocator')
path = require "path"
async = require "async"
_ = require('underscore')
logger = require('logger-sharelatex')
docComparitor = require('./DocLinesComparitor')
projectUpdateHandler = require('./ProjectUpdateHandler')
DocstoreManager = require "../Docstore/DocstoreManager"
ProjectGetter = require "./ProjectGetter"
CooldownManager = require '../Cooldown/CooldownManager'
DocumentUpdaterHandler = require('../../Features/DocumentUpdater/DocumentUpdaterHandler')
SafePath = require './SafePath'

module.exports = ProjectEntityHandler =
	getAllFolders: (project_id,  callback) ->
		logger.log project_id:project_id, "getting all folders for project"
		ProjectGetter.getProjectWithoutDocLines project_id, (err, project) ->
			return callback(err) if err?
			return callback("no project") if !project?
			ProjectEntityHandler.getAllFoldersFromProject project, callback

	getAllDocs: (project_id, callback) ->
		logger.log project_id:project_id, "getting all docs for project"

		# We get the path and name info from the project, and the lines and
		# version info from the doc store.
		DocstoreManager.getAllDocs project_id, (error, docContentsArray) ->
			return callback(error) if error?

			# Turn array from docstore into a dictionary based on doc id
			docContents = {}
			for docContent in docContentsArray
				docContents[docContent._id] = docContent

			ProjectEntityHandler.getAllFolders project_id, (error, folders = {}) ->
				return callback(error) if error?
				docs = {}
				for folderPath, folder of folders
					for doc in (folder.docs or [])
						content = docContents[doc._id.toString()]
						if content?
							docs[path.join(folderPath, doc.name)] = {
								_id:   doc._id
								name:  doc.name
								lines: content.lines
								rev:   content.rev
							}
				logger.log count:_.keys(docs).length, project_id:project_id, "returning docs for project"
				callback null, docs

	getAllFiles: (project_id, callback) ->
		logger.log project_id:project_id, "getting all files for project"
		@getAllFolders project_id, (err, folders = {}) ->
			return callback(err) if err?
			files = {}
			for folderPath, folder of folders
				for file in (folder.fileRefs or [])
					if file?
						files[path.join(folderPath, file.name)] = file
			callback null, files

	getAllFoldersFromProject: (project, callback) ->
		folders = {}
		processFolder = (basePath, folder) ->
			folders[basePath] = folder
			for childFolder in (folder.folders or [])
				if childFolder.name?
					processFolder path.join(basePath, childFolder.name), childFolder

		processFolder "/", project.rootFolder[0]
		callback null, folders

	getAllEntitiesFromProject: (project, callback) ->
		logger.log project:project, "getting all files for project"
		@getAllFoldersFromProject project, (err, folders = {}) ->
			return callback(err) if err?
			docs = []
			files = []
			for folderPath, folder of folders
				for doc in (folder.docs or [])
					if doc?
						docs.push({path: path.join(folderPath, doc.name), doc:doc})
				for file in (folder.fileRefs or [])
					if file?
						files.push({path: path.join(folderPath, file.name), file:file})
			callback null, docs, files

	getAllDocPathsFromProject: (project, callback) ->
		logger.log project:project, "getting all docs for project"
		@getAllFoldersFromProject project, (err, folders = {}) ->
			return callback(err) if err?
			docPath = {}
			for folderPath, folder of folders
				for doc in (folder.docs or [])
					docPath[doc._id] = path.join(folderPath, doc.name)
			logger.log count:_.keys(docPath).length, project_id:project._id, "returning docPaths for project"
			callback null, docPath

	flushProjectToThirdPartyDataStore: (project_id, callback) ->
		self = @
		logger.log project_id:project_id, "flushing project to tpds"
		DocumentUpdaterHandler.flushProjectToMongo project_id, (error) ->
			return callback(error) if error?
			ProjectGetter.getProject project_id, {name:true}, (error, project) ->
				return callback(error) if error?
				requests = []
				self.getAllDocs project_id, (error, docs) ->
					return callback(error) if error?
					for docPath, doc of docs
						do (docPath, doc) ->
							requests.push (cb) ->
								tpdsUpdateSender.addDoc {project_id:project_id, doc_id:doc._id, path:docPath, project_name:project.name, rev:doc.rev||0}, cb
					self.getAllFiles project_id, (error, files) ->
						return callback(error) if error?
						for filePath, file of files
							do (filePath, file) ->
								requests.push (cb) ->
									tpdsUpdateSender.addFile {project_id:project_id, file_id:file._id, path:filePath, project_name:project.name, rev:file.rev}, cb
						async.series requests, (err) ->
							logger.log project_id:project_id, "finished flushing project to tpds"
							callback(err)

	setRootDoc: (project_id, newRootDocID, callback = (error) ->)->
		logger.log project_id: project_id, rootDocId: newRootDocID, "setting root doc"
		Project.update {_id:project_id}, {rootDoc_id:newRootDocID}, {}, callback

	unsetRootDoc: (project_id, callback = (error) ->) ->
		logger.log project_id: project_id, "removing root doc"
		Project.update {_id:project_id}, {$unset: {rootDoc_id: true}}, {}, callback

	getDoc: (project_id, doc_id, options = {}, callback = (error, lines, rev) ->) ->
		if typeof(options) == "function"
			callback = options
			options = {}

		if options["pathname"]
			delete options["pathname"]
			projectLocator.findElement {project_id: project_id, element_id: doc_id, type: 'doc'}, (error, doc, path) =>
				return callback(error) if error?
				DocstoreManager.getDoc project_id, doc_id, options, (error, lines, rev, version, ranges) =>
					callback(error, lines, rev, version, ranges, path.fileSystem)
		else
			DocstoreManager.getDoc project_id, doc_id, options, callback

	addDoc: (project_or_id, folder_id, docName, docLines, userId, callback = (error, doc, folder_id) ->)=>
		ProjectEntityHandler.addDocWithoutUpdatingHistory project_or_id, folder_id, docName, docLines, userId, (error, doc, folder_id, path) ->
			return callback(error) if error?
			newDocs = [
				doc: doc
				path: path
				docLines: docLines.join('\n')
			]
			project_id = project_or_id._id or project_or_id
			DocumentUpdaterHandler.updateProjectStructure project_id, userId, {newDocs}, (error) ->
				return callback(error) if error?
				callback null, doc, folder_id

	addDocWithoutUpdatingHistory: (project_or_id, folder_id, docName, docLines, userId, callback = (error, doc, folder_id) ->)=>
		# This method should never be called directly, except when importing a project
		# from Overleaf. It skips sending updates to the project history, which will break
		# the history unless you are making sure it is updated in some other way.
		getProject = (cb) ->
			if project_or_id._id? # project
				return cb(null, project_or_id)
			else # id
				# need to retrieve full project structure to check for duplicates
				return ProjectGetter.getProject project_or_id, {rootFolder:true, name:true}, cb
		getProject (error, project) ->
			if err?
				logger.err project_id:project_id, err:err, "error getting project for add doc"
				return callback(err)
			ProjectEntityHandler._addDocWithProject project, folder_id, docName, docLines, userId, callback

	_addDocWithProject: (project, folder_id, docName, docLines, userId, callback = (error, doc, folder_id, path) ->)=>
		# check if docname is allowed
		if not SafePath.isCleanFilename docName
			return callback new Errors.InvalidNameError("invalid element name")
		project_id = project._id
		logger.log project_id: project_id, folder_id: folder_id, doc_name: docName, "adding doc to project with project"
		confirmFolder project, folder_id, (folder_id)=>
			doc = new Doc name: docName
			# Put doc in docstore first, so that if it errors, we don't have a doc_id in the project
			# which hasn't been created in docstore.
			DocstoreManager.updateDoc project_id.toString(), doc._id.toString(), docLines, 0, {}, (err, modified, rev) ->
				return callback(err) if err?

				ProjectEntityHandler._putElement project, folder_id, doc, "doc", (err, result)=>
					return callback(err) if err?
					tpdsUpdateSender.addDoc {
						project_id:   project_id,
						doc_id:		  doc?._id
						path:         result?.path?.fileSystem,
						project_name: project.name,
						rev:          0
					}, (err) ->
						return callback(err) if err?
						callback(null, doc, folder_id, result?.path?.fileSystem)

	restoreDoc: (project_id, doc_id, name, callback = (error, doc, folder_id) ->) ->
		# check if docname is allowed (passed in from client so we check it)
		if not SafePath.isCleanFilename name
			return callback new Errors.InvalidNameError("invalid element name")
		# getDoc will return the deleted doc's lines, but we don't actually remove
		# the deleted doc, just create a new one from its lines.
		ProjectEntityHandler.getDoc project_id, doc_id, include_deleted: true, (error, lines) ->
			return callback(error) if error?
			ProjectEntityHandler.addDoc project_id, null, name, lines, callback

	addFileWithoutUpdatingHistory: (project_id, folder_id, fileName, path, userId, callback = (error, fileRef, folder_id, path, fileStoreUrl) ->)->
		# check if file name is allowed
		if not SafePath.isCleanFilename fileName
			return callback new Errors.InvalidNameError("invalid element name")
		ProjectGetter.getProject project_id, {rootFolder:true, name:true}, (err, project) ->
			if err?
				logger.err project_id:project_id, err:err, "error getting project for add file"
				return callback(err)
			logger.log project_id: project._id, folder_id: folder_id, file_name: fileName, path:path, "adding file"
			return callback(err) if err?
			confirmFolder project, folder_id, (folder_id)->
				fileRef = new File name : fileName
				FileStoreHandler.uploadFileFromDisk project._id, fileRef._id, path, (err, fileStoreUrl)->
					if err?
						logger.err err:err, project_id: project._id, folder_id: folder_id, file_name: fileName, fileRef:fileRef, "error uploading image to s3"
						return callback(err)
					ProjectEntityHandler._putElement project, folder_id, fileRef, "file", (err, result)=>
						if err?
							logger.err err:err, project_id: project._id, folder_id: folder_id, file_name: fileName, fileRef:fileRef, "error adding file with project"
							return callback(err)
						tpdsUpdateSender.addFile {project_id:project._id, file_id:fileRef._id, path:result?.path?.fileSystem, project_name:project.name, rev:fileRef.rev}, (err) ->
							return callback(err) if err?
							callback(null, fileRef, folder_id, result?.path?.fileSystem, fileStoreUrl)

	addFile:  (project_id, folder_id, fileName, fsPath, userId, callback = (error, fileRef, folder_id) ->)->
		ProjectEntityHandler.addFileWithoutUpdatingHistory project_id, folder_id, fileName, fsPath, userId, (error, fileRef, folder_id, path, fileStoreUrl) ->
			return callback(error) if error?
			newFiles = [
				file: fileRef
				path: path
				url: fileStoreUrl
			]
			DocumentUpdaterHandler.updateProjectStructure project_id, userId, {newFiles}, (error) ->
				return callback(error) if error?
				callback null, fileRef, folder_id

	replaceFile: (project_id, file_id, fsPath, userId, callback)->
		self = ProjectEntityHandler
		FileStoreHandler.uploadFileFromDisk project_id, file_id, fsPath, (err, fileStoreUrl)->
			return callback(err) if err?
			ProjectGetter.getProject project_id, {rootFolder: true, name:true}, (err, project) ->
				return callback(err) if err?
				# Note there is a potential race condition here (and elsewhere)
				# If the file tree changes between findElement and the Project.update
				# then the path to the file element will be out of date. In practice
				# this is not a problem so long as we do not do anything longer running
				# between them (like waiting for the file to upload.)
				projectLocator.findElement {project:project, element_id: file_id, type: 'file'}, (err, fileRef, path)=>
					return callback(err) if err?
					tpdsUpdateSender.addFile {project_id:project._id, file_id:fileRef._id, path:path.fileSystem, rev:fileRef.rev+1, project_name:project.name}, (err) ->
						return callback(err) if err?
						conditions = _id:project._id
						inc = {}
						inc["#{path.mongo}.rev"] = 1
						set = {}
						set["#{path.mongo}.created"] = new Date()
						update =
							"$inc": inc
							"$set": set
						Project.findOneAndUpdate conditions, update, { "new": true}, (err) ->
							return callback(err) if err?
							newFiles = [
								file: fileRef
								path: path.fileSystem
								url: fileStoreUrl
							]
							DocumentUpdaterHandler.updateProjectStructure project_id, userId, {newFiles}, callback

	copyFileFromExistingProjectWithProject: (project, folder_id, originalProject_id, origonalFileRef, userId, callback = (error, fileRef, folder_id) ->)->
		project_id = project._id
		logger.log { project_id, folder_id, originalProject_id, origonalFileRef }, "copying file in s3 with project"
		return callback(err) if err?
		confirmFolder project, folder_id, (folder_id)=>
			if !origonalFileRef?
				logger.err { project_id, folder_id, originalProject_id, origonalFileRef }, "file trying to copy is null"
				return callback()
			# convert any invalid characters in original file to '_'
			fileRef = new File name : SafePath.clean(origonalFileRef.name)
			FileStoreHandler.copyFile originalProject_id, origonalFileRef._id, project._id, fileRef._id, (err, fileStoreUrl)->
				if err?
					logger.err { err, project_id, folder_id, originalProject_id, origonalFileRef }, "error coping file in s3"
					return callback(err)
				ProjectEntityHandler._putElement project, folder_id, fileRef, "file", (err, result)=>
					if err?
						logger.err { err, project_id, folder_id }, "error putting element as part of copy"
						return callback(err)
					tpdsUpdateSender.addFile { project_id, file_id:fileRef._id, path:result?.path?.fileSystem, rev:fileRef.rev, project_name:project.name}, (err) ->
						if err?
							logger.err { err, project_id, folder_id, originalProject_id, origonalFileRef }, "error sending file to tpds worker"
						newFiles = [
							file: fileRef
							path: result?.path?.fileSystem
							url: fileStoreUrl
						]
						DocumentUpdaterHandler.updateProjectStructure project_id, userId, {newFiles}, (error) ->
							return callback(error) if error?
							callback null, fileRef, folder_id

	mkdirp: (project_id, path, callback = (err, newlyCreatedFolders, lastFolderInPath)->)->
		self = @
		folders = path.split('/')
		folders = _.select folders, (folder)->
			return folder.length != 0

		ProjectGetter.getProjectWithOnlyFolders project_id, (err, project)=>
			if path == '/'
				logger.log project_id: project._id, "mkdir is only trying to make path of / so sending back root folder"
				return callback(null, [], project.rootFolder[0])
			logger.log project_id: project._id, path:path, folders:folders, "running mkdirp"

			builtUpPath = ''
			procesFolder = (previousFolders, folderName, callback)=>
				previousFolders = previousFolders || []
				parentFolder = previousFolders[previousFolders.length-1]
				if parentFolder?
					parentFolder_id = parentFolder._id
				builtUpPath = "#{builtUpPath}/#{folderName}"
				projectLocator.findElementByPath project, builtUpPath, (err, foundFolder)=>
					if !foundFolder?
						logger.log path:path, project_id:project._id, folderName:folderName, "making folder from mkdirp"
						@addFolder project_id, parentFolder_id, folderName, (err, newFolder, parentFolder_id)->
							return callback(err) if err?
							newFolder.parentFolder_id = parentFolder_id
							previousFolders.push newFolder
							callback null, previousFolders
					else
						foundFolder.filterOut = true
						previousFolders.push foundFolder
						callback  null, previousFolders


			async.reduce folders, [], procesFolder, (err, folders)->
				return callback(err) if err?
				lastFolder = folders[folders.length-1]
				folders = _.select folders, (folder)->
					!folder.filterOut
				callback(null, folders, lastFolder)

	addFolder: (project_id, parentFolder_id, folderName, callback) ->
		ProjectGetter.getProject project_id, {rootFolder:true, name:true}, (err, project)=>
			if err?
				logger.err project_id:project_id, err:err, "error getting project for add folder"
				return callback(err)
			ProjectEntityHandler.addFolderWithProject project, parentFolder_id, folderName, callback

	addFolderWithProject: (project, parentFolder_id, folderName, callback = (err, folder, parentFolder_id)->) ->
		# check if folder name is allowed
		if not SafePath.isCleanFilename folderName
			return callback new Errors.InvalidNameError("invalid element name")
		confirmFolder project, parentFolder_id, (parentFolder_id)=>
			folder = new Folder name: folderName
			logger.log project: project._id, parentFolder_id:parentFolder_id, folderName:folderName, "adding new folder"
			ProjectEntityHandler._putElement project, parentFolder_id, folder, "folder", (err, result)=>
				if err?
					logger.err err:err, project_id:project._id, "error adding folder to project"
					return callback(err)
				callback(err, folder, parentFolder_id)

	updateDocLines : (project_id, doc_id, lines, version, ranges, callback = (error) ->)->
		ProjectGetter.getProjectWithoutDocLines project_id, (err, project)->
			return callback(err) if err?
			return callback(new Errors.NotFoundError("project not found")) if !project?
			logger.log project_id: project_id, doc_id: doc_id, "updating doc lines"
			projectLocator.findElement {project:project, element_id:doc_id, type:"docs"}, (err, doc, path)->
				if err?
					logger.error err: err, doc_id: doc_id, project_id: project_id, lines: lines, "error finding doc while updating doc lines"
					return callback err
				if !doc?
					error = new Errors.NotFoundError("doc not found")
					logger.error err: error, doc_id: doc_id, project_id: project_id, lines: lines, "doc not found while updating doc lines"
					return callback(error)

				logger.log project_id: project_id, doc_id: doc_id, "telling docstore manager to update doc"
				DocstoreManager.updateDoc project_id, doc_id, lines, version, ranges, (err, modified, rev) ->
					if err?
						logger.error err: err, doc_id: doc_id, project_id:project_id, lines: lines, "error sending doc to docstore"
						return callback(err)
					logger.log project_id: project_id, doc_id: doc_id, modified:modified, "finished updating doc lines"
					if modified
						# Don't need to block for marking as updated
						projectUpdateHandler.markAsUpdated project_id
						tpdsUpdateSender.addDoc {project_id:project_id, path:path.fileSystem, doc_id:doc_id, project_name:project.name, rev:rev}, callback
					else
						callback()

	moveEntity: (project_id, entity_id, destFolderId, entityType, userId, callback = (error) ->)->
		self = @
		logger.log {entityType, entity_id, project_id, destFolderId}, "moving entity"
		if !entityType?
			logger.err {err: "No entityType set", project_id, entity_id}
			return callback("No entityType set")
		entityType = entityType.toLowerCase()
		ProjectGetter.getProject project_id, {rootFolder:true, name:true}, (err, project)=>
			return callback(err) if err?
			projectLocator.findElement {project, element_id: entity_id, type: entityType}, (err, entity, entityPath)->
				return callback(err) if err?
				self._checkValidMove project, entityType, entity, entityPath, destFolderId, (error) ->
					return callback(error) if error?
					self.getAllEntitiesFromProject project, (error, oldDocs, oldFiles) =>
						return callback(error) if error?
						self._removeElementFromMongoArray Project, project_id, entityPath.mongo, (err, newProject)->
							return callback(err) if err?
							self._putElement newProject, destFolderId, entity, entityType, (err, result, newProject)->
								return callback(err) if err?
								opts =
									project_id: project_id
									project_name: project.name
									startPath: entityPath.fileSystem
									endPath: result.path.fileSystem,
									rev: entity.rev
								tpdsUpdateSender.moveEntity opts
								self.getAllEntitiesFromProject newProject, (error, newDocs, newFiles) =>
									return callback(error) if error?
									DocumentUpdaterHandler.updateProjectStructure project_id, userId, {oldDocs, newDocs, oldFiles, newFiles}, callback

	_checkValidMove: (project, entityType, entity, entityPath, destFolderId, callback = (error) ->) ->
		projectLocator.findElement { project, element_id: destFolderId, type:"folder"}, (err, destEntity, destFolderPath) ->
			return callback(err) if err?
			# check if there is already a doc/file/folder with the same name
			# in the destination folder
			ProjectEntityHandler.checkValidElementName destEntity, entity.name, (err)->
				return callback(err) if err?
				if entityType.match(/folder/)
					logger.log destFolderPath: destFolderPath.fileSystem, folderPath: entityPath.fileSystem, "checking folder is not moving into child folder"
					isNestedFolder = destFolderPath.fileSystem.slice(0, entityPath.fileSystem.length) == entityPath.fileSystem
					if isNestedFolder
						return callback(new Errors.InvalidNameError("destination folder is a child folder of me"))
				callback()

	deleteEntity: (project_id, entity_id, entityType, userId, callback = (error) ->)->
		self = @
		logger.log entity_id:entity_id, entityType:entityType, project_id:project_id, "deleting project entity"
		if !entityType?
			logger.err err: "No entityType set", project_id: project_id, entity_id: entity_id
			return callback("No entityType set")
		entityType = entityType.toLowerCase()
		ProjectGetter.getProject project_id, {name:true, rootFolder:true}, (err, project)=>
			return callback(error) if error?
			projectLocator.findElement {project: project, element_id: entity_id, type: entityType}, (error, entity, path)=>
				return callback(error) if error?
				ProjectEntityHandler._cleanUpEntity project, entity, entityType, path.fileSystem, userId, (error) ->
					return callback(error) if error?
					tpdsUpdateSender.deleteEntity project_id:project_id, path:path.fileSystem, project_name:project.name, (error) ->
						return callback(error) if error?
						self._removeElementFromMongoArray Project, project_id, path.mongo, (error) ->
							return callback(error) if error?
							callback null


	renameEntity: (project_id, entity_id, entityType, newName, userId, callback)->
		# check if name is allowed
		if not SafePath.isCleanFilename newName
			return callback new Errors.InvalidNameError("invalid element name")
		logger.log(entity_id: entity_id, project_id: project_id, ('renaming '+entityType))
		if !entityType?
			logger.err err: "No entityType set", project_id: project_id, entity_id: entity_id
			return callback("No entityType set")
		entityType = entityType.toLowerCase()
		ProjectGetter.getProject project_id, {rootFolder:true, name:true}, (error, project)=>
			return callback(error) if error?
			ProjectEntityHandler.getAllEntitiesFromProject project, (error, oldDocs, oldFiles) =>
				return callback(error) if error?
				projectLocator.findElement {project:project, element_id:entity_id, type:entityType}, (error, entity, entPath, parentFolder)=>
					return callback(error) if error?
					# check if the new name already exists in the current folder
					ProjectEntityHandler.checkValidElementName parentFolder, newName, (error) =>
						return callback(error) if error?
						endPath = path.join(path.dirname(entPath.fileSystem), newName)
						conditions = {_id:project_id}
						update = "$set":{}
						namePath = entPath.mongo+".name"
						update["$set"][namePath] = newName
						tpdsUpdateSender.moveEntity({project_id:project_id, startPath:entPath.fileSystem, endPath:endPath, project_name:project.name, rev:entity.rev})
						Project.findOneAndUpdate conditions, update, { "new": true}, (error, newProject) ->
							return callback(error) if error?
							ProjectEntityHandler.getAllEntitiesFromProject newProject, (error, newDocs, newFiles) =>
								return callback(error) if error?
								DocumentUpdaterHandler.updateProjectStructure project_id, userId, {oldDocs, newDocs, oldFiles, newFiles}, callback

	_cleanUpEntity: (project, entity, entityType, path, userId, callback = (error) ->) ->
		if(entityType.indexOf("file") != -1)
			ProjectEntityHandler._cleanUpFile project, entity, path, userId, callback
		else if (entityType.indexOf("doc") != -1)
			ProjectEntityHandler._cleanUpDoc project, entity, path, userId, callback
		else if (entityType.indexOf("folder") != -1)
			ProjectEntityHandler._cleanUpFolder project, entity, path, userId, callback
		else
			callback()

	_cleanUpDoc: (project, doc, path, userId, callback = (error) ->) ->
		project_id = project._id.toString()
		doc_id = doc._id.toString()
		unsetRootDocIfRequired = (callback) =>
			if project.rootDoc_id? and project.rootDoc_id.toString() == doc_id
				@unsetRootDoc project_id, callback
			else
				callback()

		unsetRootDocIfRequired (error) ->
			return callback(error) if error?
			DocumentUpdaterHandler.deleteDoc project_id, doc_id, (error) ->
				return callback(error) if error?
				ProjectEntityHandler._insertDeletedDocReference project._id, doc, (error) ->
					return callback(error) if error?
					DocstoreManager.deleteDoc project_id, doc_id, (error) ->
						return callback(error) if error?
						changes = oldDocs: [ {doc, path} ]
						DocumentUpdaterHandler.updateProjectStructure project_id, userId, changes, callback

	_cleanUpFile: (project, file, path, userId, callback = (error) ->) ->
		project_id = project._id.toString()
		file_id = file._id.toString()
		FileStoreHandler.deleteFile project_id, file_id, (error) ->
			return callback(error) if error?
			changes = oldFiles: [ {file, path} ]
			DocumentUpdaterHandler.updateProjectStructure project_id, userId, changes, callback

	_cleanUpFolder: (project, folder, folderPath, userId, callback = (error) ->) ->
		jobs = []
		for doc in folder.docs
			do (doc) ->
				docPath = path.join(folderPath, doc.name)
				jobs.push (callback) -> ProjectEntityHandler._cleanUpDoc project, doc, docPath, userId, callback

		for file in folder.fileRefs
			do (file) ->
				filePath = path.join(folderPath, file.name)
				jobs.push (callback) -> ProjectEntityHandler._cleanUpFile project, file, filePath, userId, callback

		for childFolder in folder.folders
			do (childFolder) ->
				folderPath = path.join(folderPath, childFolder.name)
				jobs.push (callback) -> ProjectEntityHandler._cleanUpFolder project, childFolder, folderPath, userId, callback

		async.series jobs, callback

	_removeElementFromMongoArray : (model, model_id, path, callback = (err, project) ->)->
		conditions = {_id:model_id}
		update = {"$unset":{}}
		update["$unset"][path] = 1
		model.update conditions, update, {}, (err)->
			pullUpdate = {"$pull":{}}
			nonArrayPath = path.slice(0, path.lastIndexOf("."))
			pullUpdate["$pull"][nonArrayPath] = null
			model.findOneAndUpdate conditions, pullUpdate, {"new": true}, callback

	_insertDeletedDocReference: (project_id, doc, callback = (error) ->) ->
		Project.update {
			_id: project_id
		}, {
			$push: {
				deletedDocs: {
					_id:  doc._id
					name: doc.name
				}
			}
		}, {}, callback


	_countElements : (project, callback)->

		countFolder = (folder, cb = (err, count)->)->

			jobs = _.map folder?.folders, (folder)->
				(asyncCb)-> countFolder folder, asyncCb

			async.series jobs, (err, subfolderCounts)->
				total = 0

				if subfolderCounts?.length > 0
					total = _.reduce subfolderCounts, (a, b)-> return a + b
				if folder?.folders?.length?
					total += folder?.folders?.length
				if folder?.docs?.length?
					total += folder?.docs?.length
				if folder?.fileRefs?.length?
					total += folder?.fileRefs?.length
				cb(null, total)

		countFolder project.rootFolder[0], callback

	_putElement: (project, folder_id, element, type, callback = (err, path, project)->)->
		sanitizeTypeOfElement = (elementType)->
			lastChar = elementType.slice -1
			if lastChar != "s"
				elementType +="s"
			if elementType == "files"
				elementType = "fileRefs"
			return elementType

		if !element? or !element._id?
			e = new Error("no element passed to be inserted")
			logger.err project_id:project._id, folder_id:folder_id, element:element, type:type, "failed trying to insert element as it was null"
			return callback(e)
		type = sanitizeTypeOfElement type

		# original check path.resolve("/", element.name) isnt "/#{element.name}" or element.name.match("/")
		# check if name is allowed
		if not SafePath.isCleanFilename element.name
			e = new Errors.InvalidNameError("invalid element name")
			logger.err project_id:project._id, folder_id:folder_id, element:element, type:type, "failed trying to insert element as name was invalid"
			return callback(e)

		if !folder_id?
			folder_id = project.rootFolder[0]._id
		ProjectEntityHandler._countElements project, (err, count)->
			if count > settings.maxEntitiesPerProject
				logger.warn project_id:project._id, "project too big, stopping insertions"
				CooldownManager.putProjectOnCooldown(project._id)
				return callback("project_has_to_many_files")
			projectLocator.findElement {project:project, element_id:folder_id, type:"folders"}, (err, folder, path)=>
				if err?
					logger.err err:err, project_id:project._id, folder_id:folder_id, type:type, element:element, "error finding folder for _putElement"
					return callback(err)
				newPath =
					fileSystem: "#{path.fileSystem}/#{element.name}"
					mongo: path.mongo
				# check if the path would be too long
				if not SafePath.isAllowedLength newPath.fileSystem
					return callback new Errors.InvalidNameError("path too long")
				ProjectEntityHandler.checkValidElementName folder, element.name, (err) =>
					return callback(err) if err?
					id = element._id+''
					element._id = require('mongoose').Types.ObjectId(id)
					conditions = _id:project._id
					mongopath = "#{path.mongo}.#{type}"
					update = "$push":{}
					update["$push"][mongopath] = element
					logger.log project_id: project._id, element_id: element._id, fileType: type, folder_id: folder_id, mongopath:mongopath, "adding element to project"
					Project.findOneAndUpdate conditions, update, {"new": true}, (err, project)->
						if err?
							logger.err err: err, project_id: project._id, 'error saving in putElement project'
							return callback(err)
						callback(err, {path:newPath}, project)


	checkValidElementName: (folder, name, callback = (err) ->) ->
		# check if the name is already taken by a doc, file or
		# folder. If so, return an error "file already exists".
		err = new Errors.InvalidNameError("file already exists")
		for doc in folder?.docs or []
			return callback(err) if doc.name is name
		for file in folder?.fileRefs or []
			return callback(err) if file.name is name
		for folder in folder?.folders or []
			return callback(err) if folder.name is name
		callback()

confirmFolder = (project, folder_id, callback)->
	logger.log folder_id:folder_id, project_id:project._id, "confirming folder in project"
	if folder_id+'' == 'undefined'
		callback(project.rootFolder[0]._id)
	else if folder_id != null
		callback folder_id
	else
		callback(project.rootFolder[0]._id)
