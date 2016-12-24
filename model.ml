open Core.Std
open Async.Std

module Coordinate = struct
  type t = { x : float; y : float; z : float } with sexp
  let dist a b =
    let dx = b.x -. a.x in
    let dy = b.y -. a.y in
    let dz = b.z -. a.z in
    sqrt ((dx ** 2.) +. (dy ** 2.) +. (dz ** 2.))
end

module Virtual_pixel = struct
  type t =
    { controller_id : int
    ; strip_id : int
    ; pixel_id : int
    ; coord : Coordinate.t
    ; mutable color : Color.t }
  with sexp
end
  
module Virtual_strip = struct
  type t =
    { controller_id : int
    ; strip_id : int
    ; way_points : Coordinate.t list }
  with sexp
end

type t =
  { virtual_strips : Virtual_strip.t list
  ; virtual_pixels : Virtual_pixel.t list }
with sexp

let signum f =
  if f > 0 then 1
  else if f < 0 then -1
  else 0

let bres3d ~start ~stop =
  (* this is kind of awful *)
  let i = Float.to_int in
  let f = Float.of_int in
  let startx = i start.Coordinate.x in
  let starty = i start.Coordinate.y in
  let startz = i start.Coordinate.z in
  let stopx = i stop.Coordinate.x in
  let stopy = i stop.Coordinate.y in
  let stopz = i stop.Coordinate.z in
  let dx = stopx - startx in
  let dy = stopy - starty in
  let dz = stopz - startz in
  let ax = (abs dx) lsl 1 in
  let ay = (abs dy) lsl 1 in
  let az = (abs dz) lsl 1 in
  let signx = signum dx in
  let signy = signum dy in
  let signz = signum dz in
  let x = ref startx in
  let y = ref starty in
  let z = ref startz in
  let save acc = { Coordinate.x=f !x; y=f !y; z=f !z } :: acc in
  if ax >= max ay az then (* x dominant *)
    let deltay = ref (ay - (ax lsr 1)) in
    let deltaz = ref (az - (ax lsr 1)) in
    let rec loop acc =
      let acc = save acc in
      if !x = stopx then acc
      else begin
	if !deltay >= 0 then begin
	  y := !y + signy;
	  deltay := !deltay - ax
	end;
	if !deltaz >= 0 then begin
	  z := !z + signz;
	  deltaz := !deltaz - ax
	end;
	x := !x + signx;
	deltay := !deltay + ay;
	deltaz := !deltaz + az;
	loop acc
      end
    in loop []
  else if ay >= max ax az then (* y dominant *)
    let deltax = ref (ax - (ay lsr 1)) in
    let deltaz = ref (az - (ay lsr 1)) in
    let rec loop acc =
      let acc = save acc in
      if !y = stopy then acc
      else begin
	if !deltax >= 0 then begin
	  x := !x + signx;
	  deltax := !deltax - ay
	end;
	if !deltaz >= 0 then begin
	  z := !z + signz;
	  deltaz := !deltaz + ay
	end;
	y := !y + signy;
	deltax := !deltax + ax;
	deltaz := !deltaz + az;
	loop acc
      end
    in loop []
  else if az >= max ax ay then (* z dominant *)
    let deltax = ref (ax - (az lsr 1)) in
    let deltay = ref (ay - (az lsr 1)) in
    let rec loop acc =
      let acc = save acc in
      if !z = stopz then acc
      else begin
	if !deltax >= 0 then begin
	  x := !x + signx;
	  deltax := !deltax - az
	end;
	if !deltay >= 0 then begin
	  y := !y + signy;
	  deltay := !deltay + az
	end;
	z := !z + signz;
	deltax := !deltax + ax;
	deltay := !deltay + ay;
	loop acc
      end
    in loop []
  else
    failwithf "bres3d: invalid args" ()

let rasterize strips =
  let pixels =
    List.concat_map strips ~f:(fun strip ->
      match strip.Virtual_strip.way_points with
	| _ :: [] | [] -> assert false
	| hd :: tl ->
	  List.fold_left tl ~init:(hd, []) ~f:(fun (prev, acc) cur ->
	    let coords =
	      List.mapi (bres3d ~start:prev ~stop:cur) ~f:(fun pixel_id coord ->
		{ Virtual_pixel.
		  strip_id = strip.Virtual_strip.strip_id
		; controller_id = strip.Virtual_strip.controller_id
		; pixel_id
		; coord = coord
		; color = Color.black })
	    in
	    cur, (coords @ acc)) |> snd)
  in
  printf "*** Converted %d strips to %d pixels\n" (List.length strips) (List.length pixels);
  pixels
	  
let load path =
  Reader.file_lines path >>| fun lines ->
  let virtual_strips = 
    List.filter_map lines ~f:(fun line ->
      let line = String.strip line in
      if line = "" || line.[0] = '#' then None
      else
	match String.split ~on:'|' line with
	  | controller_and_strip_id :: points :: [] ->
	    begin match String.split ~on:':' controller_and_strip_id with
	      | controller_id :: strip_id :: [] ->
		let controller_id = Int.of_string controller_id in
		let strip_id = Int.of_string strip_id in
		let way_points =
		  let points = String.split ~on:';' (String.strip points) in
		  List.map points ~f:(fun point ->
		    match String.split ~on:',' (String.strip point) with
		      | x :: y :: z :: [] ->
			{ Coordinate.
			  x = Float.of_string x -. 140. (* hax *)
			; y = Float.of_string y
			; z = Float.of_string z }
		      | _lst ->
			failwithf "way-point '%s' not of the form 'x,y,z'" point ())
		in
		if (List.length way_points) < 2 then
		  failwithf "too few waypoints '%s'" line ();
		Some { Virtual_strip.controller_id; strip_id; way_points }
	      | _lst ->
		failwithf "'%s' is not format 'controller_id:strip_id'"
		  controller_and_strip_id ()
	    end
	  | _lst ->
	    failwithf "line '%s' split on | into too many parts" line ())
  in
  (* List.iter virtual_strips ~f:(fun strip ->
    print_endline (Virtual_strip.sexp_of_t strip |> Sexp.to_string_hum ~indent:2)); *)
  let virtual_pixels = rasterize virtual_strips in
  { virtual_strips; virtual_pixels }

let dup t =
  { t with
    virtual_pixels = (* force a deep copy *)
      List.map t.virtual_pixels ~f:(fun vp -> { vp with Virtual_pixel.color = vp.Virtual_pixel.color }) }
