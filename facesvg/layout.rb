###########################################################
# Licensed under the MIT license
###########################################################
require 'sketchup'
require 'extensions'
require 'LangHandler'

# Provides SVG module with SVG::Canvas class
Sketchup.require('facesvg/constants')
Sketchup.require('facesvg/su_util')
Sketchup.require('facesvg/svg')

module FaceSVG
  module Layout
    ################
    class ProfileCollection
      # Used to transform the points in a face loop, and find the min,max x,y in
      #   the z=0 plane
      def initialize(title)
        @title = title
        reset()
      end
      ################
      # TODO: Use a map to hold the faces??,
      #   to allow for an observer to update the layout if elements are deleted
      def reset
        # UI: reset the layout state and clear any existing profile group
        if su_profilegrp(create: false)
          FaceSVG.dbg('Remove %s', @su_profilegrp)
          Sketchup.active_model.entities.erase_entities @su_profilegrp
        end

        @su_profilegrp = nil # grp to hold all the SU face groups

        # Information to manage the layout, maxx, maxy updated in layout_facegrp
        @layoutx, @layouty, @rowheight = [CFG.layout_spacing, CFG.layout_spacing, 0.0]
      end

      ################
      def makesvg(name, index, *grps)
        bnds2d = Bounds2d.new.update(*grps)
        viewport = [0.0, 0.0, bnds2d.maxx-bnds2d.minx, bnds2d.maxy-bnds2d.miny]
        fname = format(name, index)
        svg = SVG::Canvas.new(fname, viewport, CFG.units, CFG.facesvg_version)
        svg.title(format('%s cut profile %s', @title, index))
        svg.desc(format('Shaper cut profile from Sketchup model %s', @title))

        grps.each do |g|
          # Get a surface (to calculate pocket offset if needed)
          faces = g.entities.grep(Sketchup::Face)
          surface = faces.find { |f| f.material == SURFACE }
          # Use tranform if index nil? - means all svg in one file, SINGLE_FILE
          xf = index.nil? ? g.transformation : IDENTITY
          faces.each { |f| svg.addpaths(xf, f, surface) }
        end
        svg
      end
      ################
      def write
        # UI: write any layed out profiles as svg
        grps = su_profilegrp.entities.grep(Sketchup::Group)

        if CFG.svg_output == MULTI_FILE
          # Multi file - generate multiple "svg::Canvas"
          outpath = UI.select_directory(SVG_OUTPUT_DIRECTORY, CFG.default_dir)
          return false if outpath.nil?
          CFG.default_dir = outpath
          name = "#{@title}%s.svg"
          svglist = grps.each_with_index.map { |g, i| makesvg(name, i, g) }
        else
          # single_file - generate one "svg::Canvas" with all face grps
          outpath = UI.savepanel(SVG_OUTPUT_FILE,
                                 CFG.default_dir, "#{@title}.svg")
          return false if outpath.nil?
          CFG.default_dir = File.dirname(outpath)
          name = File.basename(outpath)
          svglist = [makesvg(name, nil, *grps)]
        end

        svglist.each do |svg|
          File.open(File.join(CFG.default_dir, svg.filename), 'w') { |file| svg.write(file) }
        end
      end
      ################
      def process_selection
        # UI: process any selected faces and lay out into profile grp
        layout_facegrps(*Sketchup.active_model.selection(&:valid?).grep(Sketchup::Face))
      end

      ################
      def su_profilegrp(create: true)
        # Find or create the group for the profile entities
        return @su_profilegrp if @su_profilegrp && @su_profilegrp.valid?
        @su_profilegrp = Sketchup::active_model.entities.grep(Sketchup::Group)
                                 .find { |g| g.name==PROFILE_GROUP && g.valid? }
        return @su_profilegrp if @su_profilegrp
        # None existing, create (unless flag false)
        return nil unless create
        @su_profilegrp = Sketchup.active_model.entities.add_group()
      end
      ################
      def empty?
        su_profilegrp(create: false).nil?
      end
      ################
      def add_su_facegrp(facegrp)
        # Add new element to existing profile group by recreating the group
        su_profilegrp.layer = Sketchup.active_model.layers[0]
        @su_profilegrp = Sketchup.active_model.entities
                                 .add_group(@su_profilegrp.explode + [facegrp])
        @su_profilelayer = Sketchup.active_model.layers.add(PROFILE_LAYER)
        @su_profilegrp.name = PROFILE_GROUP
        @su_profilegrp.layer = @su_profilelayer
      end
      ################
      def layout_facegrps(*su_faces)
        FaceSVG.capture_faceprofiles(*su_faces) do |new_entities, bnds2d|
          layout_xf = Geom::Transformation
                      .new([@layoutx - bnds2d.minx, @layouty - bnds2d.miny, 0.0])
          # explode, work around more weird behavior with Arcs?
          # Transform them and then add them back into a group
          Sketchup.active_model.entities.transform_entities(layout_xf, new_entities)

          newgrp = su_profilegrp.entities.add_group(new_entities)
          FaceSVG.dbg('Face %s  layout x,y %s %s', bnds2d, @layoutx, @layoutx)
          add_su_facegrp(newgrp)

          @layoutx += CFG.layout_spacing + bnds2d.maxx - bnds2d.minx
          # As each element is layed out horizontally, keep track of the tallest bit
          @rowheight = [@rowheight, bnds2d.maxy - bnds2d.miny].max
          if @layoutx > CFG.layout_width
            @layoutx = 0.0 + CFG.layout_spacing
            @layouty += @rowheight + CFG.layout_spacing
            @rowheight = 0.0
          end
        end
      end

      ################
    end
  end
end
