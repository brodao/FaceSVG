Sketchup.require('facesvg/constants')
Sketchup.require('facesvg/reorder') # for reorder function and Line/Arc classes

module FaceSVG
  module SVG
    extend self

    FMT = '%0.3f'.freeze

    def V2d(*args)
      args = args[0].to_a if args.size == 1
      Vn.new(args[0, 2])
    end

    class Vn < Array
      # A simple vector supporting scalar multiply and vector add, % dot product, magnitude
      def initialize(elts); concat(elts); end
      def *(scalar); Vn.new(map { |c| c * scalar }); end
      def +(v2); Vn.new(zip(v2).map { |c, v| c + v }); end
      def -(v2); Vn.new(zip(v2).map { |c, v| c - v }); end
      def %(v2); zip(v2).map { |c, v| c * v }.reduce(:+); end
      def abs(); map { |c| c * c }.reduce(:+)**0.5; end
      def ==(v2); (self - v2).abs < 0.0005; end
      def inspect(); '(' + map { |c| FMT % c }.join(',') + ')'; end
      def to_s; inspect; end
      def x; self[0]; end
      def y; self[1]; end
    end

    # Sketchup is a mess - it draws curves and keeps information about them
    #  but treats everything as edges
    # Create class to aggregate ArcCurve with its associated Edges
    class SVGArc
      # Arc has a sequence of Sketchup::Edge (line) segments, and a curve object
      # with accurate arc information
      def initialize(xform, arcglob)
        @glob = arcglob
        @crv = @glob.crv
        # Ensure the edges are ordered as a path

        @centerxy = V2d(@crv.center.transform(xform))
        @startxy = V2d(@glob.startpos.transform(xform))
        @endxy = V2d(@glob.endpos.transform(xform))

        ellipse_parameters()
        FaceSVG.dbg("Defining SVGArc start, end, center '%s' '%s' '%s'",
                    @startxy, @endxy, @centerxy)
      end

      attr_reader :startxy
      attr_reader :midxy
      attr_reader :endxy

      # https://gamedev.stackexchange.com/questions/45412/
      #    understanding-math-used-to-determine-if-vector-is-clockwise-counterclockwise-f

      # cw in svg coordinate space, +y is down
      def cw_normal(v0)
        V2d(-v0.y, v0.x)
      end

      def sweep()
        # Calculate the sweep to midpoint, < 180 degrees,
        # same as finding if (center -> start)
        # is clockwise rotation from (center -> midpoint)
        c_to_s = (@startxy - @centerxy)
        c_to_e = (@midxy - @centerxy)
        c_to_e.dot(cw_normal(c_to_s)) > 0 ? '1' : '0'
      end

      # curve has curve.center, .radius, .xaxis, .yaxis,
      # .start_angle, .end_angle, see Sketchup API
      # Note, now all paths are transformed to z=0. So start using 2d
      # https://en.wikipedia.org/wiki/Ellipse  See Ellipse as an affine image,
      # specifically cot(2t) = ((f1 * f1) - (f2 * f2)) / 2( f1 * f2 )
      # cot is just 1/tan, so...
      def ellipse_parameters
        # circle, axes are orthogonal, same length (compared subject to Skecthup "tolerance")
        if ((@crv.xaxis dot @crv.yaxis) == 0 and
            (@crv.xaxis.length == @crv.yaxis.length))
          @vx = V2d(@crv.xaxis)
          @vy = V2d(@crv.yaxis)
          @rx = @ry = @crv.radius
        else
          f1 = V2d(@crv.xaxis)
          f2 = V2d(@crv.yaxis)
          vertex_angle1 = 0.5 * Math.atan2(((f1 dot f2) * 2), ((f1 dot f1) - (f2 dot f2)))
          # Get the two vertices "x" and "y"
          @vx = ellipseXY_at_angle(vertex_angle1)
          @vy = ellipseXY_at_angle(vertex_angle1 + Math::PI/2)
          # ellipse radii are magnitude of x,y vertex vectors
          @rx = @vx.abs
          @ry = @vy.abs
        end
        # Angle of "x" vertex vector
        @xrot = (@vx.x == 0) ? 90 : Math.atan(@vx.y / @vx.x)
        @xrotdeg = @xrot.radians # converted from radians

        @midxy = nil
        midangle = (@crv.end_angle + @crv.start_angle)/2.0
        @midxy = ellipseXY_at_angle(midangle, absolute: true)

        # Draw large arcs as two arcs, instead of using flag, to handle closed path case
        @largearc = (@crv.end_angle - @crv.start_angle) > Math::PI
      end

      def ellipseXY_at_angle(ang, absolute: false)
        # Return point on ellipse at angle, relative to center.  If absolute, add center
        p = V2d(@crv.xaxis) * Math.cos(ang) + V2d(@crv.yaxis)*Math.sin(ang)
        p = p + @centerxy if absolute
        p
      end

      # Always set large arc FLAG to 0, just draw as two arcs if arc > PI.
      # This works for degenerate case where start==end
      SVG_ARC_FORMAT = " A #{FMT} #{FMT} #{FMT} 0 %s #{FMT} #{FMT}".freeze
      def svgdata(prev)
        sweep_fl = sweep()
        FaceSVG.dbg('Center %s vx %s vy %s Orig start,end angle %s,%s',
                    @centerxy, @vx, @vy, @crv.start_angle.radians,
                    @crv.end_angle.radians)

        FaceSVG.dbg('Move to %s', @startxy) if prev.nil?
        FaceSVG.dbg('Arc to mid %s', @midxy) if @largearc
        FaceSVG.dbg('Arc to %s', @endxy)

        # If first path (prev is nil) output "move",
        # Then draw arc to end, with arc to midpoint if "largarc"
        ((prev.nil? ? format("M #{FMT} #{FMT}", @startxy.x, startxy.y) : '') +
          (@largearc ?
            format(SVG_ARC_FORMAT, @rx, @ry, @xrotdeg, sweep_fl, @midxy.x, @midxy.y)
            : '') +
          format(SVG_ARC_FORMAT, @rx, @ry, @xrotdeg, sweep_fl, @endxy.x, @endxy.y))
      end
    end

    class SVGSegment
      # Edge is a single line segment with a start and end x,y
      def initialize(xform, edgeglob)
        @glob = edgeglob
        @startxy = V2d(@glob.startpos.transform(xform))
        @endxy = V2d(@glob.endpos.transform(xform))
      end
      attr_reader :startxy
      attr_reader :endxy

      def svgdata(prev)
        # If first path (prev is nil) output "move", rest just line draw
        FaceSVG.dbg('Move to %s', @startxy) if prev.nil?
        FaceSVG.dbg('Line to %s', @endxy)

        (prev.nil? ? "M #{FMT} #{FMT}" % @startxy : '') + (
          " L #{FMT} #{FMT}" % @endxy)
      end
    end

    BKGBOX = "new #{FMT} #{FMT} #{FMT} #{FMT}".freeze
    VIEWBOX = "new #{FMT} #{FMT} #{FMT} #{FMT}".freeze
    # Class used to collect the output paths to be emitted as SVG
    class Canvas
      def initialize(fname, viewport, unit, version)
        @filename = fname
        @minx, @miny, @maxx, @maxy = viewport
        @width = @maxx - @minx
        @height = @maxy - @miny
        @unit = unit

        @root = Node
                .new('svg',
                     attrs: {
                       'enable-background' => format(BKGBOX, @minx, @miny, @maxx, @maxy),
                       'height' => format("#{FMT}#{@unit}", @height),
                       'width' => format("#{FMT}#{@unit}", @width),
                       'version' => '1.1', # SVG VERSION
                       'viewBox' => format(VIEWBOX, @minx, @miny, @maxx, @maxy),
                       'x' => format("#{FMT}#{@unit}", @minx),
                       'y' => format("#{FMT}#{@unit}", @minx),
                       'xmlns' => 'http://www.w3.org/2000/svg',
                       'xmlns:xlink' => 'http://www.w3.org/1999/xlink',
                       'xmlns:shaper' => 'http://www.shapertools.com/namespaces/shaper',
                       'shaper:sketchupaddin' => version # plugin version
                     })
      end

      attr_reader :filename

      # Set the SVG model title
      def title(text); @root.add_child(Node.new('title', text: text)); end
      # Set the SVG model description
      def desc(text); @root.add_child(Node.new('desc', text: text)); end

      # Add an SVG path node
      #
      # ==== Attributes
      #
      # * +data+ - SVG path node 'd' sttribute, like "M 0 0 L 0 1 L 1 1 Z"
      # * +fill+ - rgb for fill, like "rgb(0,0,0)" as a string.
      # * +stroke+ - rgb for path stroke
      # * +stroke_width+ - pixel width for path stroke
      # * +path_type+ - "exterior" or "interior" or "edge???"
      # * +cut_depth+ - depth in inches? for cutter head.  Unclear how this should be set.
      def path(data, fill: nil, stroke: nil, stroke_width: nil, path_type: 'exterior',
               vector_effect: 'non-scaling-stroke', cut_depth: '0.0125')
        # yet another hash syntax, since keys are not symbols
        p = Node
            .new('path',
                 attrs: {
                   'd'=> data,
                   'vector-effect' => vector_effect,
                   'shaper:cutDepth' => cut_depth,
                   'shaper:pathType' => path_type })
        p.add_attr('fill', fill) if fill
        p.add_attr('stroke', stroke) if stroke
        p.add_attr('stroke-width', stroke_width) if stroke_width

        @root.add_child(p)
      end

      def write(file)
        file.write("<!-- ARC is A xrad yrad xrotation-degrees largearc sweep end_x end_y -->\n")
        @root.write(file)
      end

      def addpaths(face, surface)
        # Only do outer loop for pocket faces
        if face.material == POCKET
          paths = [face.outer_loop]
          depth = FaceSVG.face_offset(face, surface)
          profile_kind = PK_POCKET
        else
          profile_kind = nil # set for each loop on face
          paths = face.loops
          depth = CFG.cut_depth
        end

        paths.each do |loop|
          profile_kind = profile_kind || (loop == face.outer_loop) ? PK_OUTER : PK_INNER
          FaceSVG.dbg('Profile, %s edges, %s %s', loop.edges.size, profile_kind, depth)
          # regroup edges so arc edges are grouped with metadata, all ordered end to start
          curves = [] # Keep track of processed arcs
          pathparts = loop.edges.map { |edge|
            Arc.create(curves, edge) || Line.create(edge)
          }.reject(&:nil?)
          pathparts = FaceSVG.reorder(pathparts)
          svgloop = Loop.create(pathparts, profile_kind, depth)
          svg.path(svgloop.svgdata, svgloop.attributes)
        end
      end
    end

    class Node
      # Simple Node object to construct SVG XML output (no built in support for XML in ruby)

      def initialize(name, attrs: nil, text: nil)
        @name = name
        # attribute map
        @attrs = attrs or {}
        # node text
        @text = text
        # node children
        @children = []
      end

      def add_attr(name, value); @attrs[name] = value; end
      def add_text(text); @text = text; end
      def add_child(node); @children << node; end

      def write(file)
        file.write("\n<#{@name} ")
        @attrs and @attrs.each { |k, v| file.write("#{k}='#{v}' ") }
        if @children.length == 0 and not @text
          file.write('/>')
        else
          file.write('>')
          file.write(@text) if @text
          @children.each { |c| c.write(file) }
          file.write("\n</#{@name}>")
        end
      end
    end

    ## open path cut
    class Edge
      def initialize(points)
        @points = points
      end
    end

    class Loop
      # class Loop factory method.  See "Globs" in layout.rb, basically
      # to aggregate edges with arc metadata, and deal with ordering
      def self.create(xform, glob_arr, kind, depth)
        Loop.new(
          glob_arr.map { |glob|
            glob.isArc() ? SVGArc.new(xform, glob) : SVGSegment.new(xform, glob)
          }, kind, depth)
      end

      # Oh, since @attributes are used to pass arguments, they have to
      #  use this other hash syntax...
      def initialize(pathparts, kind, depth)
        # pathparts: array of SVGArcs and SVGSegments
        @pathparts = pathparts
        if kind == PK_OUTER
          @attributes = { path_type: kind, depth: depth, fill: 'rgb(0,0,0)' }
        elsif kind == PK_POCKET
          @attributes = { path_type: kind, depth: depth, fill: 'rgb(128,128,128)',
            stroke_width: '2', stroke: 'rgb(128,128,128)' }
        elsif kind == PK_INNER
          @attributes = { path_type: kind, depth: depth, fill: 'rgb(255,255,255)',
            stroke_width: '2', stroke: 'rgb(0,0,0)' }
        else # PK_GUIDE, let's not fill, could be problematic
          @attributes = { path_type: kind, stroke_width: '2', stroke: 'rgb(20,110,255)' }
        end
      end

      attr_reader :attributes

      # Append all individual path data parts, with Z at end to closepath
      def svgdata
        prev = nil
        (@pathparts.map { |p| d = p.svgdata(prev); prev = p; d }).join(' ') + ' Z'
      end
    end
  end
end
