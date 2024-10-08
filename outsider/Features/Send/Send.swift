//
//  Send.swift
//  outsider
//
//  Created by Michael Jach on 11/09/2024.
//

import SwiftUI
import ComposableArchitecture
import PhotosUI
import Supabase

@Reducer
struct Send {
  @Dependency(\.supabase) var supabase
  
  @ObservableState
  struct State: Equatable {
    var currentUser: CurrentUserModel
    var prompt = ""
    var tempImage: UIImage?
    var imageSelection: PhotosPickerItem?
    var isPending = false
    var isFormDisabled: Bool {
      isPending || (prompt.isEmpty && tempImage == nil)
    }
    var focusedField: Field?
    
    enum Field: String, Hashable {
      case send
    }
  }
  
  enum Action {
    case onPromptChanged(prompt: String)
    case send
    case didSend(Result<PostModel, Error>)
    case imageSelectionChanged(PhotosPickerItem?)
    case didImageSelect(UIImage?)
    case clearImages
    case setFocusedField(State.Field?)
    
    // Sub actions
  }
  
  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {  
      case .setFocusedField(let field):
        state.focusedField = field
        return .none
        
      case .clearImages:
        state.imageSelection = nil
        state.tempImage = nil
        return .none
        
      case .imageSelectionChanged(let selection):
        state.imageSelection = selection
        return .run { send in
          let image = try await selection!.loadTransferable(type: Data.self)!
          let uiImage = UIImage(data: image)?.resizeImage(targetSize: CGSize(width: 1600, height: 1600))
          await send(.didImageSelect(uiImage))
        }
        
      case .didImageSelect(let uiImage):
        state.tempImage = uiImage
        return .none
        
      case .onPromptChanged(let prompt):
        state.prompt = prompt
        return .none
        
      case .send:
        state.isPending = true
        let prompt = state.prompt
        let tempImage = state.tempImage
        state.prompt = ""
        state.tempImage = nil
        state.imageSelection = nil
        return .run { [currentUser = state.currentUser] send in
          do {
            let postUuid = UUID()
            let mediaUuid = UUID()
            
            if let tempImage = tempImage {
              try await supabase.storage
                .from("media")
                .upload(
                  path: "\(postUuid)/\(mediaUuid).png",
                  file: tempImage.jpegData(compressionQuality: 0.8)!,
                  options: FileOptions(upsert: true)
                )
              
              let publicURL = try supabase.storage
                .from("media")
                .getPublicURL(path: "\(postUuid)/\(mediaUuid).png")
              
              try await supabase
                .from("media")
                .insert(MediaModel(
                  uuid: mediaUuid,
                  url: publicURL.absoluteString,
                  post_uuid: postUuid
                ))
                .execute()
            }
            
            try await supabase
              .from("posts")
              .insert(PostModelInsert(
                uuid: postUuid,
                text: prompt,
                author: currentUser.uuid,
                is_comment: false
              ))
              .execute()
            
            if tempImage != nil {
              try await supabase
                .from("posts_media")
                .insert(PostMediaInsert(post_uuid: postUuid, media_uuid: mediaUuid))
                .execute()
            }
            
            let post: PostModel = try await supabase
              .from("posts")
              .select(
                """
                  uuid,
                  is_comment,
                  text,
                  created_at,
                  author!inner(*),
                  media(*),
                  likes(*),
                  commentsCount:posts_comments!posts_comments_post_uuid_fkey(
                    count
                  )
                """
              )
              .eq("uuid", value: postUuid)
              .single()
              .execute()
              .value
            
            await send(.didSend(.success(post)))
          } catch {
            await send(.didSend(.failure(error)))
          }
        }
        
      case .didSend(.success(_)):
        state.isPending = false
        return .none
        
      case .didSend(.failure(let error)):
        state.isPending = false
        print(error)
        return .none
      }
    }
  }
}
